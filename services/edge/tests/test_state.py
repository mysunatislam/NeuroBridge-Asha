from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest

from fingerspeak_edge.adapters import DisplayMode
from fingerspeak_edge.protocol import (
    CaptionSet,
    EmergencyDisplay,
    PairingAuthenticate,
    parse_client_message,
)
from fingerspeak_edge.state import ProtocolViolation
from tests.helpers import DEVICE_ID, client_message, make_runtime, pairing_message


@pytest.mark.asyncio
async def test_pairing_code_is_consumed_and_rotated_to_device_credential() -> None:
    runtime = make_runtime()
    request = parse_client_message(json.dumps(pairing_message()))
    assert isinstance(request, PairingAuthenticate)

    _, first = await runtime.authenticate(request)

    credential = first.payload.device_credential
    assert credential is not None
    assert len(credential) >= 32
    with pytest.raises(ProtocolViolation, match="already been consumed"):
        await runtime.authenticate(request)

    reconnect_raw = pairing_message(credential, credential_kind="device_credential")
    reconnect = parse_client_message(json.dumps(reconnect_raw))
    assert isinstance(reconnect, PairingAuthenticate)
    _, accepted = await runtime.authenticate(reconnect)
    assert accepted.payload.device_credential is None


@pytest.mark.asyncio
async def test_status_uses_null_for_unavailable_batteries() -> None:
    runtime = make_runtime()
    await runtime.start()
    try:
        request = parse_client_message(json.dumps(pairing_message()))
        assert isinstance(request, PairingAuthenticate)
        await runtime.authenticate(request)

        status = await runtime.status_message()

        assert status.payload.phone_connected is True
        assert status.payload.display_connected is True
        assert status.payload.camera_status == "ready"
        assert status.payload.tracking_status == "tracking"
        assert status.payload.pi_battery_percent is None
        assert status.payload.wheelchair_battery_percent is None
    finally:
        await runtime.stop()


@pytest.mark.asyncio
async def test_display_commands_are_idempotent_and_message_id_collision_is_rejected() -> None:
    runtime = make_runtime()
    await runtime.start()
    try:
        auth = parse_client_message(json.dumps(pairing_message()))
        assert isinstance(auth, PairingAuthenticate)
        connection_id, _ = await runtime.authenticate(auth)
        command_id = str(uuid4())
        raw = client_message(
            "caption.set",
            {"text": "Good morning.", "language": "en-US"},
            message_id=command_id,
        )
        command = parse_client_message(json.dumps(raw))
        assert isinstance(command, CaptionSet)

        first = await runtime.command_ack(connection_id, command)
        duplicate = await runtime.command_ack(connection_id, command)

        assert first.payload.accepted is True
        assert first.payload.duplicate is False
        assert duplicate.payload.duplicate is True
        assert len(runtime.display.history) == 1  # type: ignore[attr-defined]

        changed = client_message(
            "caption.set",
            {"text": "Different content.", "language": "en-US"},
            message_id=command_id,
        )
        changed_command = parse_client_message(json.dumps(changed))
        assert isinstance(changed_command, CaptionSet)
        with pytest.raises(ProtocolViolation, match="different command content"):
            await runtime.command_ack(connection_id, changed_command)
    finally:
        await runtime.stop()


@pytest.mark.asyncio
async def test_active_emergency_has_priority_until_expiry() -> None:
    now = datetime(2026, 8, 22, 12, 0, tzinfo=UTC)
    runtime = make_runtime(wall_clock=lambda: now)
    await runtime.start()
    try:
        auth_raw = pairing_message()
        auth_raw["sent_at"] = now.isoformat()
        auth = parse_client_message(json.dumps(auth_raw, ensure_ascii=False))
        assert isinstance(auth, PairingAuthenticate)
        connection_id, _ = await runtime.authenticate(auth)
        emergency_raw = client_message(
            "emergency.display",
            {
                "text": "Help requested",
                "language": "en-US",
                "expires_at": (now + timedelta(minutes=2)).isoformat(),
            },
            sent_at=now.isoformat(),
        )
        emergency = parse_client_message(json.dumps(emergency_raw))
        assert isinstance(emergency, EmergencyDisplay)
        emergency_ack = await runtime.command_ack(connection_id, emergency)
        assert emergency_ack.payload.accepted is True

        caption_raw = client_message(
            "caption.set",
            {"text": "Routine caption", "language": "en-US"},
            sent_at=now.isoformat(),
        )
        caption = parse_client_message(json.dumps(caption_raw))
        assert isinstance(caption, CaptionSet)
        caption_ack = await runtime.command_ack(connection_id, caption)

        assert caption_ack.payload.accepted is False
        assert (await runtime.display.current(now)).mode is DisplayMode.emergency
    finally:
        await runtime.stop()


@pytest.mark.asyncio
async def test_wrong_device_and_stale_message_are_rejected() -> None:
    now = datetime(2026, 8, 22, 12, 0, tzinfo=UTC)
    runtime = make_runtime(wall_clock=lambda: now)
    wrong = pairing_message()
    wrong["device_id"] = "another-pi"
    wrong["sent_at"] = now.isoformat()
    request = parse_client_message(json.dumps(wrong))
    assert isinstance(request, PairingAuthenticate)
    with pytest.raises(ProtocolViolation) as wrong_error:
        await runtime.authenticate(request)
    assert wrong_error.value.code == "wrong_device"

    stale = pairing_message()
    stale["device_id"] = DEVICE_ID
    stale["sent_at"] = (now - timedelta(hours=1)).isoformat()
    request = parse_client_message(json.dumps(stale))
    assert isinstance(request, PairingAuthenticate)
    with pytest.raises(ProtocolViolation) as stale_error:
        await runtime.authenticate(request)
    assert stale_error.value.code == "stale_message"
