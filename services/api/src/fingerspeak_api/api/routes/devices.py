from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Annotated, Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, WebSocket, WebSocketDisconnect, status
from pydantic import Field, TypeAdapter, ValidationError
from sqlalchemy import and_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from fingerspeak_api.api.dependencies import (
    Actor,
    ActorDep,
    DBSession,
    get_profile_for_actor,
)
from fingerspeak_api.config import Settings, get_settings
from fingerspeak_api.database import get_db_session, utcnow
from fingerspeak_api.models import DeviceCaption, DeviceState, RegisteredDevice
from fingerspeak_api.schemas import (
    DeviceCaptionAckMessage,
    DeviceCaptionCreate,
    DeviceCaptionRead,
    DevicePingMessage,
    DeviceStateRead,
    DeviceTelemetryMessage,
    RegisteredDeviceCreate,
    RegisteredDeviceProvisioned,
    RegisteredDeviceRead,
)
from fingerspeak_api.security import websocket_origin_is_allowed
from fingerspeak_api.services.devices import (
    bearer_token,
    create_device_token,
    device_hub,
    device_token_matches,
)

router = APIRouter(prefix="/devices", tags=["devices"])

DeviceInbound = Annotated[
    DeviceTelemetryMessage | DeviceCaptionAckMessage | DevicePingMessage,
    Field(discriminator="type"),
]
DEVICE_INBOUND_ADAPTER = TypeAdapter(DeviceInbound)


async def _get_device_for_actor(
    db: AsyncSession,
    device_id: UUID,
    actor: Actor,
    *,
    owner_only: bool,
) -> RegisteredDevice:
    device = await db.get(RegisteredDevice, device_id)
    if device is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Device not found")
    await get_profile_for_actor(db, device.profile_id, actor, owner_only=owner_only)
    return device


def _aware(value: datetime) -> datetime:
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)


def _device_read(
    device: RegisteredDevice,
    state_record: DeviceState | None,
    settings: Settings,
    *,
    now: datetime | None = None,
) -> RegisteredDeviceRead:
    current_time = now or utcnow()
    last_state = None
    online = False
    if state_record is not None:
        last_seen_at = _aware(state_record.last_seen_at)
        online = device.enabled and (current_time - last_seen_at) <= timedelta(
            seconds=settings.device_online_ttl_seconds
        )
        last_state = DeviceStateRead(
            sequence=state_record.sequence,
            observed_at=state_record.observed_at,
            last_seen_at=state_record.last_seen_at,
            pi_battery_percent=state_record.pi_battery_percent,
            wheelchair_battery_percent=state_record.wheelchair_battery_percent,
            wheelchair_status=state_record.wheelchair_status,  # type: ignore[arg-type]
            camera_status=state_record.camera_status,  # type: ignore[arg-type]
            display_status=state_record.display_status,  # type: ignore[arg-type]
            transport=state_record.transport,  # type: ignore[arg-type]
        )
    return RegisteredDeviceRead(
        id=device.id,
        profile_id=device.profile_id,
        name=device.name,
        kind=device.kind,  # type: ignore[arg-type]
        enabled=device.enabled,
        online=online,
        last_state=last_state,
        created_at=device.created_at,
        updated_at=device.updated_at,
        revoked_at=device.revoked_at,
    )


def _caption_message(caption: DeviceCaption) -> dict[str, Any]:
    return {
        "type": "caption",
        "caption": DeviceCaptionRead.model_validate(caption).model_dump(mode="json"),
    }


@router.post("", response_model=RegisteredDeviceProvisioned, status_code=status.HTTP_201_CREATED)
async def register_device(
    payload: RegisteredDeviceCreate,
    db: DBSession,
    actor: ActorDep,
    settings: Annotated[Settings, Depends(get_settings)],
) -> RegisteredDeviceProvisioned:
    await get_profile_for_actor(db, payload.profile_id, actor, owner_only=True)
    token, token_sha256 = create_device_token()
    device = RegisteredDevice(
        profile_id=payload.profile_id,
        name=payload.name,
        kind=payload.kind,
        token_sha256=token_sha256,
    )
    db.add(device)
    try:
        await db.commit()
    except IntegrityError as exc:
        await db.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Device could not be registered",
        ) from exc
    await db.refresh(device)
    return RegisteredDeviceProvisioned(
        device=_device_read(device, None, settings),
        token=token,
    )


@router.get("", response_model=list[RegisteredDeviceRead])
async def list_devices(
    profile_id: UUID,
    db: DBSession,
    actor: ActorDep,
    settings: Annotated[Settings, Depends(get_settings)],
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
) -> list[RegisteredDeviceRead]:
    await get_profile_for_actor(db, profile_id, actor)
    devices = list(
        (
            await db.scalars(
                select(RegisteredDevice)
                .where(RegisteredDevice.profile_id == profile_id)
                .order_by(RegisteredDevice.created_at.desc())
                .limit(limit)
            )
        ).all()
    )
    states = (
        {
            state.device_id: state
            for state in (
                await db.scalars(
                    select(DeviceState).where(
                        DeviceState.device_id.in_([device.id for device in devices])
                    )
                )
            ).all()
        }
        if devices
        else {}
    )
    now = utcnow()
    return [_device_read(device, states.get(device.id), settings, now=now) for device in devices]


@router.delete("/{device_id}", status_code=status.HTTP_204_NO_CONTENT)
async def revoke_device(device_id: UUID, db: DBSession, actor: ActorDep) -> None:
    device = await _get_device_for_actor(db, device_id, actor, owner_only=True)
    if device.enabled:
        device.enabled = False
        device.revoked_at = utcnow()
        await db.commit()
    await device_hub.revoke(device_id)


@router.post(
    "/{device_id}/captions",
    response_model=DeviceCaptionRead,
    status_code=status.HTTP_201_CREATED,
)
async def enqueue_caption(
    device_id: UUID,
    payload: DeviceCaptionCreate,
    db: DBSession,
    actor: ActorDep,
    settings: Annotated[Settings, Depends(get_settings)],
) -> DeviceCaption:
    # An explicitly granted caregiver may write a short caption to the patient
    # display; device provisioning and revocation remain owner-only operations.
    device = await _get_device_for_actor(db, device_id, actor, owner_only=False)
    if not device.enabled:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Device is revoked")
    existing = await db.scalar(
        select(DeviceCaption).where(
            and_(
                DeviceCaption.device_id == device_id,
                DeviceCaption.client_message_id == payload.client_message_id,
            )
        )
    )
    if existing is not None:
        if existing.text != payload.text or existing.locale != payload.locale:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="client_message_id is already used by a different caption",
            )
        return existing

    now = utcnow()
    ttl_seconds = payload.ttl_seconds or settings.device_caption_ttl_seconds
    caption = DeviceCaption(
        device_id=device_id,
        client_message_id=payload.client_message_id,
        text=payload.text,
        locale=payload.locale,
        created_at=now,
        expires_at=now + timedelta(seconds=ttl_seconds),
    )
    db.add(caption)
    try:
        await db.commit()
    except IntegrityError as exc:
        await db.rollback()
        existing = await db.scalar(
            select(DeviceCaption).where(
                and_(
                    DeviceCaption.device_id == device_id,
                    DeviceCaption.client_message_id == payload.client_message_id,
                )
            )
        )
        if (
            existing is not None
            and existing.text == payload.text
            and existing.locale == payload.locale
        ):
            return existing
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Caption could not be created",
        ) from exc
    await db.refresh(caption)
    if await device_hub.publish(device_id, _caption_message(caption)):
        caption.delivered_at = utcnow()
        await db.commit()
        await db.refresh(caption)
    return caption


@router.websocket("/{device_id}/ws")
async def device_socket(
    websocket: WebSocket,
    device_id: UUID,
    db: Annotated[AsyncSession, Depends(get_db_session)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> None:
    # Credentials in query strings leak into histories and proxy logs.
    if any(
        key.lower() in {"token", "access_token", "authorization"} for key in websocket.query_params
    ):
        await websocket.close(code=4401, reason="Query-string credentials are forbidden")
        return
    origin = websocket.headers.get("origin")
    if origin is not None and not websocket_origin_is_allowed(origin, settings):
        await websocket.close(code=4403, reason="WebSocket origin is not allowed")
        return
    supplied_token = bearer_token(websocket.headers.get("authorization"))
    if supplied_token is None:
        await websocket.close(code=4401)
        return

    authorization_token = await device_hub.begin_authorization(device_id)
    device = await db.get(RegisteredDevice, device_id)
    if (
        device is None
        or not device.enabled
        or not device_token_matches(supplied_token, device.token_sha256)
    ):
        await device_hub.cancel_authorization(device_id, authorization_token)
        await db.rollback()
        await websocket.close(code=4401)
        return
    # Close the authorization read transaction without expiring the loaded device object.
    await db.commit()

    if not await device_hub.connect(device_id, authorization_token, websocket):
        return
    try:
        state_record = await db.get(DeviceState, device_id)
        await websocket.send_json(
            {
                "type": "status",
                "online": True,
                "last_state": (
                    _device_read(device, state_record, settings).last_state.model_dump(mode="json")
                    if state_record is not None
                    else None
                ),
            }
        )
        now = utcnow()
        pending = list(
            (
                await db.scalars(
                    select(DeviceCaption)
                    .where(
                        DeviceCaption.device_id == device_id,
                        DeviceCaption.acknowledged_at.is_(None),
                        DeviceCaption.expires_at > now,
                    )
                    .order_by(DeviceCaption.created_at.asc(), DeviceCaption.id.asc())
                    .limit(20)
                )
            ).all()
        )
        for caption in pending:
            await websocket.send_json(_caption_message(caption))
            if caption.delivered_at is None:
                caption.delivered_at = now
        if pending:
            await db.commit()

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
                message = DEVICE_INBOUND_ADAPTER.validate_json(raw_text)
            except ValidationError:
                await websocket.send_json({"type": "error", "detail": "Invalid device message"})
                continue

            if isinstance(message, DevicePingMessage):
                await websocket.send_json({"type": "pong"})
            elif isinstance(message, DeviceTelemetryMessage):
                await _apply_telemetry(websocket, db, device_id, message)
            else:
                await _acknowledge_caption(websocket, db, device_id, message.caption_id)
    except WebSocketDisconnect:
        pass
    finally:
        await db.rollback()
        await device_hub.disconnect(device_id, websocket)


async def _apply_telemetry(
    websocket: WebSocket,
    db: AsyncSession,
    device_id: UUID,
    message: DeviceTelemetryMessage,
) -> None:
    state_record = await db.get(DeviceState, device_id)
    if state_record is not None and message.sequence <= state_record.sequence:
        await websocket.send_json(
            {
                "type": "telemetry.rejected",
                "detail": "sequence must increase",
                "last_sequence": state_record.sequence,
            }
        )
        return
    now = utcnow()
    if state_record is None:
        state_record = DeviceState(
            device_id=device_id,
            sequence=message.sequence,
            observed_at=message.observed_at,
            last_seen_at=now,
            pi_battery_percent=message.pi_battery_percent,
            wheelchair_battery_percent=message.wheelchair_battery_percent,
            wheelchair_status=message.wheelchair_status,
            camera_status=message.camera_status,
            display_status=message.display_status,
            transport=message.transport,
        )
        db.add(state_record)
    else:
        state_record.sequence = message.sequence
        state_record.observed_at = message.observed_at
        state_record.last_seen_at = now
        # Explicit null means unavailable; never reuse a stale percentage.
        state_record.pi_battery_percent = message.pi_battery_percent
        state_record.wheelchair_battery_percent = message.wheelchair_battery_percent
        state_record.wheelchair_status = message.wheelchair_status
        state_record.camera_status = message.camera_status
        state_record.display_status = message.display_status
        state_record.transport = message.transport
    await db.commit()
    await websocket.send_json(
        {
            "type": "status",
            "online": True,
            "sequence": state_record.sequence,
            "last_seen_at": state_record.last_seen_at.isoformat(),
        }
    )


async def _acknowledge_caption(
    websocket: WebSocket,
    db: AsyncSession,
    device_id: UUID,
    caption_id: UUID,
) -> None:
    caption = await db.get(DeviceCaption, caption_id)
    now = utcnow()
    if caption is None or caption.device_id != device_id or _aware(caption.expires_at) <= now:
        await websocket.send_json({"type": "error", "detail": "Caption is unavailable"})
        return
    if caption.acknowledged_at is None:
        caption.acknowledged_at = now
        await db.commit()
    await websocket.send_json({"type": "caption.acknowledged", "caption_id": str(caption.id)})
