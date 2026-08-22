from __future__ import annotations

from dataclasses import dataclass
from typing import Annotated
from uuid import UUID

from fastapi import Depends, Header, HTTPException, Request, status
from sqlalchemy import and_, select
from sqlalchemy.ext.asyncio import AsyncSession

from fingerspeak_api.config import Settings, get_settings
from fingerspeak_api.database import get_db_session
from fingerspeak_api.models import CaregiverGrant, Profile, SessionRecord
from fingerspeak_api.security import (
    INVALID_ASSERTION,
    IdentityAssertionError,
    authenticate_actor_subject,
)

DBSession = Annotated[AsyncSession, Depends(get_db_session)]


@dataclass(frozen=True, slots=True)
class Actor:
    subject: str


async def get_actor(
    request: Request,
    settings: Annotated[Settings, Depends(get_settings)],
    x_actor_subject: Annotated[str | None, Header(alias="X-Actor-Subject")] = None,
    x_actor_timestamp: Annotated[str | None, Header(alias="X-Actor-Timestamp")] = None,
    x_actor_signature: Annotated[str | None, Header(alias="X-Actor-Signature")] = None,
) -> Actor:
    try:
        subject = authenticate_actor_subject(
            raw_subject=x_actor_subject,
            raw_timestamp=x_actor_timestamp,
            raw_signature=x_actor_signature,
            method=request.method,
            path=request.scope["path"],
            settings=settings,
        )
    except IdentityAssertionError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail=INVALID_ASSERTION
        ) from exc
    return Actor(subject)


ActorDep = Annotated[Actor, Depends(get_actor)]


async def get_profile_for_actor(
    db: AsyncSession,
    profile_id: UUID,
    actor: Actor,
    *,
    owner_only: bool = False,
) -> Profile:
    profile = await db.get(Profile, profile_id)
    if profile is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Profile not found")
    if profile.owner_subject == actor.subject:
        return profile
    if not owner_only:
        grant = await db.scalar(
            select(CaregiverGrant).where(
                and_(
                    CaregiverGrant.profile_id == profile_id,
                    CaregiverGrant.caregiver_subject == actor.subject,
                    CaregiverGrant.enabled.is_(True),
                )
            )
        )
        if grant is not None:
            return profile
    # Hide whether the resource exists from an unauthorized caller.
    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Profile not found")


async def get_session_for_actor(
    db: AsyncSession,
    session_id: UUID,
    actor: Actor,
    *,
    owner_only: bool = False,
) -> SessionRecord:
    record = await db.get(SessionRecord, session_id)
    if record is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Session not found")
    await get_profile_for_actor(db, record.profile_id, actor, owner_only=owner_only)
    return record
