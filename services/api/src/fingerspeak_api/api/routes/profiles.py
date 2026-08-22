from __future__ import annotations

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Query, Response, status
from sqlalchemy import and_, or_, select

from fingerspeak_api.api.dependencies import ActorDep, DBSession, get_profile_for_actor
from fingerspeak_api.models import CaregiverGrant, Profile
from fingerspeak_api.schemas import (
    CaregiverGrantCreate,
    CaregiverGrantRead,
    ProfileCreate,
    ProfileRead,
    ProfileUpdate,
)
from fingerspeak_api.services.alerts import alert_hub

router = APIRouter(prefix="/profiles", tags=["profiles"])


@router.post("", response_model=ProfileRead, status_code=status.HTTP_201_CREATED)
async def create_profile(payload: ProfileCreate, db: DBSession, actor: ActorDep) -> Profile:
    profile = Profile(
        owner_subject=actor.subject,
        display_name=payload.display_name,
        locale=payload.locale,
        consent_version=payload.consent_version,
        consent_granted_at=payload.consent_granted_at,
        analytics_consent=payload.analytics_consent,
        caregiver_alerts_consent=payload.caregiver_alerts_consent,
        model_sync_consent=payload.model_sync_consent,
        vocabulary=[gesture.model_dump(mode="json") for gesture in payload.vocabulary],
    )
    db.add(profile)
    await db.commit()
    await db.refresh(profile)
    return profile


@router.get("", response_model=list[ProfileRead])
async def list_profiles(
    db: DBSession,
    actor: ActorDep,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> list[Profile]:
    statement = (
        select(Profile)
        .outerjoin(
            CaregiverGrant,
            and_(
                CaregiverGrant.profile_id == Profile.id,
                CaregiverGrant.caregiver_subject == actor.subject,
                CaregiverGrant.enabled.is_(True),
            ),
        )
        .where(or_(Profile.owner_subject == actor.subject, CaregiverGrant.profile_id.is_not(None)))
        .order_by(Profile.created_at.desc())
        .offset(offset)
        .limit(limit)
        .distinct()
    )
    return list((await db.scalars(statement)).all())


@router.get("/{profile_id}", response_model=ProfileRead)
async def get_profile(profile_id: UUID, db: DBSession, actor: ActorDep) -> Profile:
    return await get_profile_for_actor(db, profile_id, actor)


@router.patch("/{profile_id}", response_model=ProfileRead)
async def update_profile(
    profile_id: UUID,
    payload: ProfileUpdate,
    db: DBSession,
    actor: ActorDep,
) -> Profile:
    profile = await get_profile_for_actor(db, profile_id, actor, owner_only=True)
    changes = payload.model_dump(exclude_unset=True, exclude_none=True)
    if "vocabulary" in changes:
        changes["vocabulary"] = [
            gesture.model_dump(mode="json") for gesture in payload.vocabulary or []
        ]
    for field, value in changes.items():
        setattr(profile, field, value)
    await db.commit()
    if changes.get("caregiver_alerts_consent") is False:
        await alert_hub.disconnect_profile(
            profile_id,
            reason="Caregiver-alert consent was withdrawn",
        )
    await db.refresh(profile)
    return profile


@router.get("/{profile_id}/caregivers", response_model=list[CaregiverGrantRead])
async def list_caregivers(profile_id: UUID, db: DBSession, actor: ActorDep) -> list[CaregiverGrant]:
    await get_profile_for_actor(db, profile_id, actor, owner_only=True)
    statement = (
        select(CaregiverGrant)
        .where(CaregiverGrant.profile_id == profile_id)
        .order_by(CaregiverGrant.created_at.asc())
    )
    return list((await db.scalars(statement)).all())


@router.put("/{profile_id}/caregivers", response_model=CaregiverGrantRead)
async def grant_caregiver(
    profile_id: UUID,
    payload: CaregiverGrantCreate,
    db: DBSession,
    actor: ActorDep,
) -> CaregiverGrant:
    await get_profile_for_actor(db, profile_id, actor, owner_only=True)
    grant = await db.get(
        CaregiverGrant,
        {"profile_id": profile_id, "caregiver_subject": payload.caregiver_subject},
    )
    if grant is None:
        grant = CaregiverGrant(
            profile_id=profile_id,
            caregiver_subject=payload.caregiver_subject,
            enabled=True,
        )
        db.add(grant)
    else:
        grant.enabled = True
    await db.commit()
    await db.refresh(grant)
    return grant


@router.delete(
    "/{profile_id}/caregivers/{caregiver_subject}", status_code=status.HTTP_204_NO_CONTENT
)
async def revoke_caregiver(
    profile_id: UUID,
    caregiver_subject: str,
    db: DBSession,
    actor: ActorDep,
) -> Response:
    profile = await get_profile_for_actor(db, profile_id, actor, owner_only=True)
    grant = await db.get(
        CaregiverGrant,
        {"profile_id": profile_id, "caregiver_subject": caregiver_subject},
    )
    if grant is not None:
        grant.enabled = False
        await db.commit()
    if caregiver_subject != profile.owner_subject:
        await alert_hub.disconnect_actor(
            profile_id,
            caregiver_subject,
            reason="Caregiver access was revoked",
        )
    return Response(status_code=status.HTTP_204_NO_CONTENT)
