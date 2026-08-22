from __future__ import annotations

import asyncio
import json
from contextlib import asynccontextmanager
from datetime import UTC, datetime, timedelta
from itertools import islice
from uuid import UUID, uuid4

import pytest
from pydantic import SecretStr

from fingerspeak_edge.cli import build_cloud_relay
from fingerspeak_edge.cloud import (
    CloudDeviceRelay,
    CloudRelaySettings,
    bounded_backoff,
    connect_cloud,
)
from tests.helpers import make_runtime

CLOUD_DEVICE_ID = UUID("8a7d44ef-4fd1-47bf-93b8-12f1778f1c21")
CLOUD_URL = f"wss://api.example/v1/devices/{CLOUD_DEVICE_ID}/ws"
CLOUD_ORIGIN = "https://patient.example"
CLOUD_TOKEN = "fsd_" + "a" * 43


class FakeCloudSocket:
    def __init__(self, incoming: list[str | bytes | Exception] | None = None) -> None:
        self.incoming: asyncio.Queue[str | bytes | Exception] = asyncio.Queue()
        for item in incoming or []:
            self.incoming.put_nowait(item)
        self.sent: list[str] = []

    async def send(self, message: str) -> None:
        self.sent.append(message)

    async def recv(self) -> str | bytes:
        item = await self.incoming.get()
        if isinstance(item, Exception):
            raise item
        return item


def relay_settings(**changes) -> CloudRelaySettings:
    values = {
        "websocket_url": CLOUD_URL,
        "origin": CLOUD_ORIGIN,
        "bearer_token": SecretStr(CLOUD_TOKEN),
        "transport": "wifi",
        "telemetry_interval_seconds": 0.1,
        "backoff_initial_seconds": 0.1,
        "backoff_max_seconds": 0.4,
        "stable_connection_seconds": 1,
    }
    values.update(changes)
    return CloudRelaySettings(**values)


def status_message(sequence: int = 40) -> str:
    now = datetime.now(UTC).isoformat()
    return json.dumps(
        {
            "type": "status",
            "online": True,
            "last_state": {
                "sequence": sequence,
                "observed_at": now,
                "last_seen_at": now,
                "pi_battery_percent": None,
                "wheelchair_battery_percent": None,
                "wheelchair_status": "unknown",
                "camera_status": "active",
                "display_status": "ready",
                "transport": "wifi",
            },
        }
    )


def caption_message(*, caption_id: UUID, text: str = "Caregiver is nearby.") -> str:
    now = datetime.now(UTC)
    return json.dumps(
        {
            "type": "caption",
            "caption": {
                "id": str(caption_id),
                "device_id": str(CLOUD_DEVICE_ID),
                "client_message_id": str(uuid4()),
                "text": text,
                "locale": "en-US",
                "created_at": now.isoformat(),
                "expires_at": (now + timedelta(minutes=2)).isoformat(),
                "delivered_at": None,
                "acknowledged_at": None,
            },
        }
    )


def test_cloud_relay_config_hides_token_and_rejects_query_credentials() -> None:
    settings = relay_settings()

    assert CLOUD_TOKEN not in repr(settings)
    assert settings.device_id == CLOUD_DEVICE_ID
    assert list(islice(bounded_backoff(settings), 4)) == [
        0.1,
        0.2,
        0.4,
        0.4,
    ]

    with pytest.raises(ValueError, match="cannot contain credentials or a query"):
        relay_settings(websocket_url=f"{CLOUD_URL}?token={CLOUD_TOKEN}")


def test_cloud_relay_is_disabled_when_cloud_configuration_is_absent(monkeypatch) -> None:
    class Args:
        cloud_device_ws_url = None
        cloud_origin = None

    monkeypatch.delenv("FINGERSPEAK_EDGE_CLOUD_DEVICE_TOKEN", raising=False)

    assert build_cloud_relay(Args(), make_runtime()) is None


@pytest.mark.asyncio
async def test_default_connector_uses_bearer_header_and_allowed_origin(monkeypatch) -> None:
    captured: dict[str, object] = {}
    socket = FakeCloudSocket()

    class FakeConnection:
        async def __aenter__(self):
            return socket

        async def __aexit__(self, *_):
            return False

    def fake_connect(url: str, **kwargs):
        captured["url"] = url
        captured.update(kwargs)
        return FakeConnection()

    monkeypatch.setattr("websockets.asyncio.client.connect", fake_connect)
    settings = relay_settings()

    async with connect_cloud(settings) as connected:
        assert connected is socket

    assert captured["url"] == CLOUD_URL
    assert captured["origin"] == CLOUD_ORIGIN
    assert captured["additional_headers"] == {"Authorization": f"Bearer {CLOUD_TOKEN}"}
    assert captured["max_size"] == settings.max_message_bytes


@pytest.mark.asyncio
async def test_telemetry_is_bounded_monotonic_and_keeps_batteries_separate() -> None:
    runtime = make_runtime()
    runtime.telemetry.pi_battery_percent = 67.4  # type: ignore[attr-defined]
    runtime.telemetry.wheelchair_battery_percent = None  # type: ignore[attr-defined]
    relay = CloudDeviceRelay(settings=relay_settings(), runtime=runtime)
    await runtime.start()
    try:
        await relay.handle_inbound(FakeCloudSocket(), status_message(40))
        first = await relay.telemetry_message()
        second = await relay.telemetry_message()

        assert first.sequence == 41
        assert second.sequence == 42
        assert first.pi_battery_percent == 67
        assert first.wheelchair_battery_percent is None
        assert first.transport == "wifi"
        assert len(first.model_dump_json().encode("utf-8")) <= relay.settings.max_message_bytes
    finally:
        await runtime.stop()


@pytest.mark.asyncio
async def test_cloud_caption_is_rendered_once_but_acknowledged_on_duplicate() -> None:
    runtime = make_runtime()
    relay = CloudDeviceRelay(settings=relay_settings(), runtime=runtime)
    socket = FakeCloudSocket()
    caption_id = uuid4()
    raw = caption_message(caption_id=caption_id, text="আমি কাছেই আছি।")
    await runtime.start()
    try:
        await relay.handle_inbound(socket, raw)
        await relay.handle_inbound(socket, raw)

        display = runtime.display
        assert len(display.history) == 1  # type: ignore[attr-defined]
        acknowledgements = [json.loads(message) for message in socket.sent]
        assert acknowledgements == [
            {"type": "caption.ack", "caption_id": str(caption_id)},
            {"type": "caption.ack", "caption_id": str(caption_id)},
        ]
    finally:
        await runtime.stop()


@pytest.mark.asyncio
async def test_reconnect_logging_never_includes_bearer_token(caplog) -> None:
    attempts = 0

    @asynccontextmanager
    async def failing_connector(_):
        nonlocal attempts
        attempts += 1
        raise RuntimeError(CLOUD_TOKEN)
        yield  # pragma: no cover

    runtime = make_runtime()
    relay = CloudDeviceRelay(
        settings=relay_settings(backoff_initial_seconds=0.01, backoff_max_seconds=0.02),
        runtime=runtime,
        connector=failing_connector,
    )
    await runtime.start()
    try:
        await relay.start()
        await asyncio.sleep(0.04)
        await relay.stop()
    finally:
        await runtime.stop()

    assert attempts >= 2
    assert CLOUD_TOKEN not in caplog.text
    assert "RuntimeError" in caplog.text
