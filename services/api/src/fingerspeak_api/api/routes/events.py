from __future__ import annotations

import json
from datetime import datetime
from typing import Annotated, Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, WebSocket, WebSocketDisconnect, status
from sqlalchemy import and_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from fingerspeak_api.api.dependencies import (
    Actor,
    ActorDep,
    DBSession,
    get_profile_for_actor,
    get_session_for_actor,
)
from fingerspeak_api.config import Settings, get_settings
from fingerspeak_api.database import get_db_session, utcnow
from fingerspeak_api.models import (
    AlertStatus,
    CaregiverAlert,
    Event,
    EventType,
    ModelVersion,
)
from fingerspeak_api.schemas import (
    CaregiverAlertCreate,
    CaregiverAlertRead,
    DerivedEventCreate,
    EventRead,
)
from fingerspeak_api.security import (
    IdentityAssertionError,
    authenticate_actor_subject,
    websocket_origin_is_allowed,
)
from fingerspeak_api.services.alerts import alert_hub

router = APIRouter(prefix="/events", tags=["events and caregiver alerts"])


def alert_message(kind: str, alert: CaregiverAlert) -> dict[str, Any]:
    return {
        "type": kind,
        "alert": CaregiverAlertRead.model_validate(alert).model_dump(mode="json"),
    }


async def validate_model_reference(
    db: AsyncSession, model_version_id: UUID | None, profile_id: UUID
) -> None:
    if model_version_id is None:
        return
    model_version = await db.get(ModelVersion, model_version_id)
    if model_version is None or model_version.profile_id != profile_id:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="model_version_id does not belong to this profile",
        )


@router.post("", response_model=EventRead, status_code=status.HTTP_201_CREATED)
async def create_event(payload: DerivedEventCreate, db: DBSession, actor: ActorDep) -> Event:
    session_record = await get_session_for_actor(db, payload.session_id, actor, owner_only=True)
    profile = await get_profile_for_actor(db, session_record.profile_id, actor, owner_only=True)
    if not profile.analytics_consent:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Analytics consent is not enabled for this profile",
        )

    existing = await db.scalar(
        select(Event).where(
            and_(
                Event.session_id == payload.session_id,
                Event.client_event_id == payload.client_event_id,
            )
        )
    )
    if existing is not None:
        if existing.event_type is EventType.caregiver_alert:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="client_event_id is already used by a caregiver alert",
            )
        return existing

    await validate_model_reference(db, payload.model_version_id, profile.id)
    values = payload.model_dump()
    record = Event(profile_id=profile.id, **values)
    db.add(record)
    try:
        await db.commit()
    except IntegrityError as exc:
        await db.rollback()
        existing = await db.scalar(
            select(Event).where(
                and_(
                    Event.session_id == payload.session_id,
                    Event.client_event_id == payload.client_event_id,
                )
            )
        )
        if existing is not None and existing.event_type is not EventType.caregiver_alert:
            return existing
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Event could not be created due to a conflicting record",
        ) from exc
    await db.refresh(record)
    return record


@router.get("", response_model=list[EventRead])
async def list_events(
    session_id: UUID,
    db: DBSession,
    actor: ActorDep,
    limit: Annotated[int, Query(ge=1, le=200)] = 100,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> list[Event]:
    await get_session_for_actor(db, session_id, actor)
    statement = (
        select(Event)
        .where(Event.session_id == session_id)
        .order_by(Event.occurred_at.asc(), Event.id.asc())
        .offset(offset)
        .limit(limit)
    )
    return list((await db.scalars(statement)).all())


@router.post(
    "/caregiver-alerts",
    response_model=CaregiverAlertRead,
    status_code=status.HTTP_201_CREATED,
)
async def create_caregiver_alert(
    payload: CaregiverAlertCreate, db: DBSession, actor: ActorDep
) -> CaregiverAlert:
    profile = await get_profile_for_actor(db, payload.profile_id, actor, owner_only=True)
    if not profile.caregiver_alerts_consent:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Caregiver-alert consent is not enabled for this profile",
        )
    session_record = await get_session_for_actor(db, payload.session_id, actor, owner_only=True)
    if session_record.profile_id != profile.id:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="session_id does not belong to this profile",
        )

    existing_event = await db.scalar(
        select(Event).where(
            and_(
                Event.session_id == payload.session_id,
                Event.client_event_id == payload.client_event_id,
            )
        )
    )
    if existing_event is not None:
        existing_alert = await db.scalar(
            select(CaregiverAlert).where(CaregiverAlert.source_event_id == existing_event.id)
        )
        if existing_alert is None:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="client_event_id is already used by a non-alert event",
            )
        return existing_alert

    received_at = utcnow()
    source_event = Event(
        profile_id=profile.id,
        session_id=payload.session_id,
        client_event_id=payload.client_event_id,
        event_type=EventType.caregiver_alert,
        occurred_at=payload.requested_at,
        created_at=received_at,
    )
    db.add(source_event)
    await db.flush()
    alert = CaregiverAlert(
        profile_id=profile.id,
        session_id=payload.session_id,
        source_event_id=source_event.id,
        severity=payload.severity,
        message=payload.message,
        created_at=received_at,
    )
    db.add(alert)
    try:
        await db.commit()
    except IntegrityError as exc:
        await db.rollback()
        existing_event = await db.scalar(
            select(Event).where(
                and_(
                    Event.session_id == payload.session_id,
                    Event.client_event_id == payload.client_event_id,
                )
            )
        )
        existing_alert = (
            await db.scalar(
                select(CaregiverAlert).where(CaregiverAlert.source_event_id == existing_event.id)
            )
            if existing_event is not None
            else None
        )
        if existing_alert is not None:
            return existing_alert
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Alert could not be created due to a conflicting record",
        ) from exc
    await db.refresh(alert)

    # Database commit happens first: a dropped socket never drops the alert itself.
    await alert_hub.publish(profile.id, alert_message("caregiver_alert.created", alert))
    return alert


@router.get("/caregiver-alerts", response_model=list[CaregiverAlertRead])
async def list_caregiver_alerts(
    profile_id: UUID,
    db: DBSession,
    actor: ActorDep,
    alert_status: Annotated[AlertStatus | None, Query(alias="status")] = None,
    after: datetime | None = None,
    limit: Annotated[int, Query(ge=1, le=500)] = 100,
) -> list[CaregiverAlert]:
    await get_profile_for_actor(db, profile_id, actor)
    statement = select(CaregiverAlert).where(CaregiverAlert.profile_id == profile_id)
    if alert_status is not None:
        statement = statement.where(CaregiverAlert.status == alert_status)
    if after is not None:
        statement = statement.where(CaregiverAlert.created_at > after)
        statement = statement.order_by(CaregiverAlert.created_at.asc(), CaregiverAlert.id.asc())
        return list((await db.scalars(statement.limit(limit))).all())

    statement = statement.order_by(
        CaregiverAlert.created_at.desc(), CaregiverAlert.id.desc()
    ).limit(limit)
    alerts = list((await db.scalars(statement)).all())
    alerts.reverse()
    return alerts


@router.post("/caregiver-alerts/{alert_id}/acknowledge", response_model=CaregiverAlertRead)
async def acknowledge_caregiver_alert(
    alert_id: UUID, db: DBSession, actor: ActorDep
) -> CaregiverAlert:
    alert = await db.get(CaregiverAlert, alert_id)
    if alert is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Alert not found")
    await get_profile_for_actor(db, alert.profile_id, actor)
    if alert.status is AlertStatus.resolved:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="A resolved alert cannot be acknowledged",
        )
    if alert.status is AlertStatus.acknowledged:
        return alert

    alert.status = AlertStatus.acknowledged
    alert.acknowledged_at = utcnow()
    alert.acknowledged_by = actor.subject
    await db.commit()
    await db.refresh(alert)
    await alert_hub.publish(alert.profile_id, alert_message("caregiver_alert.acknowledged", alert))
    return alert


@router.post("/caregiver-alerts/{alert_id}/resolve", response_model=CaregiverAlertRead)
async def resolve_caregiver_alert(alert_id: UUID, db: DBSession, actor: ActorDep) -> CaregiverAlert:
    alert = await db.get(CaregiverAlert, alert_id)
    if alert is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Alert not found")
    await get_profile_for_actor(db, alert.profile_id, actor)
    if alert.status is AlertStatus.resolved:
        return alert

    now = utcnow()
    if alert.status is AlertStatus.pending:
        alert.acknowledged_at = now
        alert.acknowledged_by = actor.subject
    alert.status = AlertStatus.resolved
    alert.resolved_at = now
    await db.commit()
    await db.refresh(alert)
    await alert_hub.publish(alert.profile_id, alert_message("caregiver_alert.resolved", alert))
    return alert


@router.websocket("/caregiver-alerts/ws")
async def caregiver_alert_socket(
    websocket: WebSocket,
    profile_id: UUID,
    db: Annotated[AsyncSession, Depends(get_db_session)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> None:
    if not websocket_origin_is_allowed(websocket.headers.get("origin"), settings):
        await websocket.close(code=4403, reason="WebSocket origin is not allowed")
        return

    try:
        actor = Actor(
            authenticate_actor_subject(
                raw_subject=websocket.headers.get("x-actor-subject"),
                raw_timestamp=websocket.headers.get("x-actor-timestamp"),
                raw_signature=websocket.headers.get("x-actor-signature"),
                method="GET",
                path=websocket.scope["path"],
                settings=settings,
            )
        )
    except IdentityAssertionError:
        await websocket.close(code=4401)
        return

    authorization_token = await alert_hub.begin_authorization(profile_id, actor.subject)
    try:
        profile = await get_profile_for_actor(db, profile_id, actor)
        caregiver_alerts_consent = profile.caregiver_alerts_consent
    except HTTPException:
        await alert_hub.cancel_authorization(profile_id, authorization_token)
        await websocket.close(code=4404)
        return
    except BaseException:
        await alert_hub.cancel_authorization(profile_id, authorization_token)
        raise
    finally:
        await db.rollback()

    if not caregiver_alerts_consent:
        await alert_hub.cancel_authorization(profile_id, authorization_token)
        await websocket.close(code=4403, reason="Caregiver-alert consent is disabled")
        return

    connected = await alert_hub.connect(
        profile_id,
        actor.subject,
        authorization_token,
        websocket,
    )
    if not connected:
        return
    try:
        # Connect first, then snapshot. A concurrent alert can be duplicated, but cannot fall into a
        # query/connect gap. Clients deduplicate by alert id.
        statement = (
            select(CaregiverAlert)
            .where(
                CaregiverAlert.profile_id == profile_id,
                CaregiverAlert.status != AlertStatus.resolved,
            )
            .order_by(CaregiverAlert.created_at.desc(), CaregiverAlert.id.desc())
            .limit(settings.alert_replay_limit)
        )
        replay = list((await db.scalars(statement)).all())
        replay.reverse()
        await db.rollback()
        await websocket.send_json(
            {
                "type": "caregiver_alert.snapshot",
                "alerts": [
                    CaregiverAlertRead.model_validate(alert).model_dump(mode="json")
                    for alert in replay
                ],
            }
        )
        while True:
            incoming = await websocket.receive()
            if incoming["type"] == "websocket.disconnect":
                raise WebSocketDisconnect(incoming.get("code", 1000))
            raw_text = incoming.get("text")
            if raw_text is None:
                await websocket.close(code=1003, reason="Text JSON messages are required")
                return
            if len(raw_text.encode("utf-8")) > settings.websocket_max_message_bytes:
                await websocket.close(code=1009, reason="WebSocket message is too large")
                return
            try:
                message = json.loads(raw_text)
            except json.JSONDecodeError:
                await websocket.send_json({"type": "error", "detail": "Invalid JSON"})
                continue
            if message == {"type": "ping"}:
                await websocket.send_json({"type": "pong"})
            else:
                await websocket.send_json(
                    {"type": "error", "detail": "Only ping messages are accepted"}
                )
    except WebSocketDisconnect:
        pass
    finally:
        await alert_hub.disconnect(profile_id, websocket)
