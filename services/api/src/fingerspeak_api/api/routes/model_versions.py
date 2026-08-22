from __future__ import annotations

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, status
from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError

from fingerspeak_api.api.dependencies import ActorDep, DBSession, get_profile_for_actor
from fingerspeak_api.database import utcnow
from fingerspeak_api.models import ModelStatus, ModelVersion
from fingerspeak_api.schemas import ModelVersionCreate, ModelVersionRead

router = APIRouter(prefix="/model-versions", tags=["model versions"])


@router.post("", response_model=ModelVersionRead, status_code=status.HTTP_201_CREATED)
async def create_model_version(
    payload: ModelVersionCreate, db: DBSession, actor: ActorDep
) -> ModelVersion:
    profile = await get_profile_for_actor(db, payload.profile_id, actor, owner_only=True)
    if not profile.model_sync_consent:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Model metadata sync consent is not enabled for this profile",
        )

    existing = await db.scalar(
        select(ModelVersion).where(
            ModelVersion.profile_id == payload.profile_id,
            ModelVersion.semantic_version == payload.semantic_version,
        )
    )
    if existing is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="This semantic version already exists for the profile",
        )

    values = payload.model_dump()
    values["metrics"] = payload.metrics.model_dump(mode="json")
    record = ModelVersion(**values)
    db.add(record)
    try:
        await db.commit()
    except IntegrityError as exc:
        await db.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="This semantic version already exists for the profile",
        ) from exc
    await db.refresh(record)
    return record


@router.get("", response_model=list[ModelVersionRead])
async def list_model_versions(
    profile_id: UUID,
    db: DBSession,
    actor: ActorDep,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
) -> list[ModelVersion]:
    await get_profile_for_actor(db, profile_id, actor)
    statement = (
        select(ModelVersion)
        .where(ModelVersion.profile_id == profile_id)
        .order_by(ModelVersion.created_at.desc())
        .limit(limit)
    )
    return list((await db.scalars(statement)).all())


@router.get("/{model_version_id}", response_model=ModelVersionRead)
async def get_model_version(model_version_id: UUID, db: DBSession, actor: ActorDep) -> ModelVersion:
    record = await db.get(ModelVersion, model_version_id)
    if record is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Model version not found")
    await get_profile_for_actor(db, record.profile_id, actor)
    return record


@router.post("/{model_version_id}/activate", response_model=ModelVersionRead)
async def activate_model_version(
    model_version_id: UUID, db: DBSession, actor: ActorDep
) -> ModelVersion:
    record = await db.get(ModelVersion, model_version_id)
    if record is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Model version not found")
    profile = await get_profile_for_actor(db, record.profile_id, actor, owner_only=True)
    if not profile.model_sync_consent:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Model metadata sync consent is not enabled for this profile",
        )
    if record.status is ModelStatus.active:
        return record
    if record.status is not ModelStatus.validated:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Only a validated model version can be activated",
        )

    await db.execute(
        update(ModelVersion)
        .where(
            ModelVersion.profile_id == record.profile_id,
            ModelVersion.status == ModelStatus.active,
        )
        .values(status=ModelStatus.validated, activated_at=None)
    )
    record.status = ModelStatus.active
    record.activated_at = utcnow()
    await db.commit()
    await db.refresh(record)
    return record
