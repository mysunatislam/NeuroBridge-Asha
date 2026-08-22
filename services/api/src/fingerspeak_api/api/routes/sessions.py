from __future__ import annotations

from datetime import UTC
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, status
from sqlalchemy import and_, select
from sqlalchemy.exc import IntegrityError

from fingerspeak_api.api.dependencies import (
    ActorDep,
    DBSession,
    get_profile_for_actor,
    get_session_for_actor,
)
from fingerspeak_api.models import ModelStatus, ModelVersion, SessionRecord
from fingerspeak_api.schemas import SessionCreate, SessionEnd, SessionRead

router = APIRouter(prefix="/sessions", tags=["sessions"])


@router.post("", response_model=SessionRead, status_code=status.HTTP_201_CREATED)
async def create_session(payload: SessionCreate, db: DBSession, actor: ActorDep) -> SessionRecord:
    await get_profile_for_actor(db, payload.profile_id, actor, owner_only=True)

    existing = await db.scalar(
        select(SessionRecord).where(
            and_(
                SessionRecord.profile_id == payload.profile_id,
                SessionRecord.client_session_id == payload.client_session_id,
            )
        )
    )
    if existing is not None:
        return existing

    if payload.model_version_id is not None:
        model_version = await db.get(ModelVersion, payload.model_version_id)
        if (
            model_version is None
            or model_version.profile_id != payload.profile_id
            or model_version.status is not ModelStatus.active
        ):
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Session model version must be active for this profile",
            )

    record = SessionRecord(**payload.model_dump())
    db.add(record)
    try:
        await db.commit()
    except IntegrityError as exc:
        await db.rollback()
        existing = await db.scalar(
            select(SessionRecord).where(
                and_(
                    SessionRecord.profile_id == payload.profile_id,
                    SessionRecord.client_session_id == payload.client_session_id,
                )
            )
        )
        if existing is not None:
            return existing
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Session could not be created due to a conflicting record",
        ) from exc
    await db.refresh(record)
    return record


@router.get("", response_model=list[SessionRead])
async def list_sessions(
    profile_id: UUID,
    db: DBSession,
    actor: ActorDep,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> list[SessionRecord]:
    await get_profile_for_actor(db, profile_id, actor)
    statement = (
        select(SessionRecord)
        .where(SessionRecord.profile_id == profile_id)
        .order_by(SessionRecord.started_at.desc())
        .offset(offset)
        .limit(limit)
    )
    return list((await db.scalars(statement)).all())


@router.get("/{session_id}", response_model=SessionRead)
async def get_session(session_id: UUID, db: DBSession, actor: ActorDep) -> SessionRecord:
    return await get_session_for_actor(db, session_id, actor)


@router.post("/{session_id}/end", response_model=SessionRead)
async def end_session(
    session_id: UUID, payload: SessionEnd, db: DBSession, actor: ActorDep
) -> SessionRecord:
    record = await get_session_for_actor(db, session_id, actor, owner_only=True)
    if record.ended_at is not None:
        return record

    started_at = record.started_at
    if started_at.tzinfo is None:
        started_at = started_at.replace(tzinfo=UTC)
    if payload.ended_at < started_at:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="ended_at cannot be earlier than started_at",
        )
    record.ended_at = payload.ended_at
    await db.commit()
    await db.refresh(record)
    return record
