from __future__ import annotations

import asyncio
import json
import logging
import re
import time
from collections import OrderedDict
from collections.abc import Callable, Iterator
from contextlib import AbstractAsyncContextManager, asynccontextmanager, suppress
from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum
from typing import Annotated, Literal, Protocol
from urllib.parse import urlsplit
from uuid import UUID

from pydantic import (
    AwareDatetime,
    BaseModel,
    ConfigDict,
    Field,
    SecretStr,
    TypeAdapter,
    ValidationError,
    field_validator,
)

from fingerspeak_edge.adapters import CameraStatus, DisplayAdapter, DisplayMode, TrackingStatus
from fingerspeak_edge.protocol import DeviceStatusPayload, normalise_display_text
from fingerspeak_edge.state import EdgeRuntime

logger = logging.getLogger(__name__)

CloudTransport = Literal["unknown", "wifi", "usb", "ethernet"]
CloudCameraStatus = Literal["unknown", "off", "ready", "active", "error"]
CloudDisplayStatus = Literal["unknown", "off", "ready", "active", "error"]


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class CloudState(StrictModel):
    sequence: Annotated[int, Field(ge=0, le=9_223_372_036_854_775_807)]
    observed_at: datetime
    last_seen_at: datetime
    pi_battery_percent: Annotated[int | None, Field(ge=0, le=100)]
    wheelchair_battery_percent: Annotated[int | None, Field(ge=0, le=100)]
    wheelchair_status: Literal["unknown", "idle", "moving", "stopped", "needs_attention"]
    camera_status: CloudCameraStatus
    display_status: CloudDisplayStatus
    transport: CloudTransport


class CloudStatus(StrictModel):
    type: Literal["status"]
    online: bool
    last_state: CloudState | None = None
    sequence: Annotated[int | None, Field(ge=0)] = None
    last_seen_at: datetime | None = None


class CloudCaption(StrictModel):
    id: UUID
    device_id: UUID
    client_message_id: UUID
    text: Annotated[str, Field(min_length=1, max_length=500)]
    locale: Annotated[
        str,
        Field(min_length=2, max_length=16, pattern=r"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$"),
    ]
    created_at: datetime
    expires_at: AwareDatetime
    delivered_at: datetime | None = None
    acknowledged_at: datetime | None = None

    @field_validator("text")
    @classmethod
    def safe_plain_text(cls, value: str) -> str:
        return normalise_display_text(value, maximum=500)


class CloudCaptionMessage(StrictModel):
    type: Literal["caption"]
    caption: CloudCaption


class CloudTelemetryRejected(StrictModel):
    type: Literal["telemetry.rejected"]
    detail: Annotated[str, Field(min_length=1, max_length=240)]
    last_sequence: Annotated[int, Field(ge=0)]


class CloudCaptionAcknowledged(StrictModel):
    type: Literal["caption.acknowledged"]
    caption_id: UUID


class CloudPong(StrictModel):
    type: Literal["pong"]


class CloudError(StrictModel):
    type: Literal["error"]
    detail: Annotated[str, Field(min_length=1, max_length=240)]


CloudInbound = Annotated[
    CloudStatus
    | CloudCaptionMessage
    | CloudTelemetryRejected
    | CloudCaptionAcknowledged
    | CloudPong
    | CloudError,
    Field(discriminator="type"),
]
CLOUD_INBOUND_ADAPTER = TypeAdapter(CloudInbound)


class CloudTelemetry(StrictModel):
    type: Literal["telemetry"] = "telemetry"
    sequence: Annotated[int, Field(ge=0, le=9_223_372_036_854_775_807)]
    observed_at: AwareDatetime
    pi_battery_percent: Annotated[int | None, Field(ge=0, le=100)]
    wheelchair_battery_percent: Annotated[int | None, Field(ge=0, le=100)]
    wheelchair_status: Literal["unknown"] = "unknown"
    camera_status: CloudCameraStatus
    display_status: CloudDisplayStatus
    transport: CloudTransport = "unknown"


class CloudCaptionAck(StrictModel):
    type: Literal["caption.ack"] = "caption.ack"
    caption_id: UUID


class CloudSocket(Protocol):
    async def send(self, message: str) -> None: ...

    async def recv(self) -> str | bytes: ...


CloudConnector = Callable[["CloudRelaySettings"], AbstractAsyncContextManager[CloudSocket]]


@dataclass(frozen=True, slots=True)
class CloudRelaySettings:
    websocket_url: str
    origin: str
    bearer_token: SecretStr = field(repr=False)
    transport: CloudTransport = "unknown"
    telemetry_interval_seconds: float = 5.0
    initial_message_timeout_seconds: float = 10.0
    backoff_initial_seconds: float = 1.0
    backoff_max_seconds: float = 30.0
    backoff_multiplier: float = 2.0
    stable_connection_seconds: float = 30.0
    max_message_bytes: int = 4_096
    caption_cache_size: int = 256

    def __post_init__(self) -> None:
        parsed = urlsplit(self.websocket_url)
        if parsed.scheme not in {"ws", "wss"} or not parsed.netloc:
            raise ValueError("cloud device WebSocket URL must use ws:// or wss://")
        if parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ValueError("cloud device WebSocket URL cannot contain credentials or a query")
        if not re.fullmatch(r"/v1/devices/[0-9a-fA-F-]{36}/ws", parsed.path):
            raise ValueError("cloud URL must target /v1/devices/{uuid}/ws")
        try:
            UUID(parsed.path.split("/")[3])
        except ValueError as exc:
            raise ValueError("cloud URL contains an invalid device UUID") from exc

        origin = urlsplit(self.origin)
        if origin.scheme not in {"http", "https"} or not origin.netloc:
            raise ValueError("cloud Origin must be an explicit http(s) origin")
        if origin.path not in {"", "/"} or origin.query or origin.fragment:
            raise ValueError("cloud Origin cannot contain a path, query, or fragment")
        token = self.bearer_token.get_secret_value()
        if not token.startswith("fsd_") or not 32 <= len(token) <= 160:
            raise ValueError("cloud device bearer token is not a provisioned FingerSpeak token")
        if not 0.1 <= self.telemetry_interval_seconds <= 300:
            raise ValueError("telemetry interval must be between 0.1 and 300 seconds")
        if not 512 <= self.max_message_bytes <= 65_536:
            raise ValueError("cloud max message bytes must be between 512 and 65536")
        if (
            self.backoff_initial_seconds <= 0
            or self.backoff_max_seconds < self.backoff_initial_seconds
        ):
            raise ValueError("cloud reconnect backoff bounds are invalid")
        if not 1 < self.backoff_multiplier <= 10:
            raise ValueError("cloud reconnect multiplier must be greater than one")
        if self.caption_cache_size < 1:
            raise ValueError("caption cache size must be positive")

    @property
    def device_id(self) -> UUID:
        return UUID(urlsplit(self.websocket_url).path.split("/")[3])


def bounded_backoff(settings: CloudRelaySettings) -> Iterator[float]:
    delay = settings.backoff_initial_seconds
    while True:
        yield delay
        delay = min(settings.backoff_max_seconds, delay * settings.backoff_multiplier)


@asynccontextmanager
async def connect_cloud(settings: CloudRelaySettings):
    from websockets.asyncio.client import connect

    # Disable the transport logger so debug handshake logging cannot expose Authorization.
    transport_logger = logging.getLogger("fingerspeak_edge.cloud_transport")
    transport_logger.disabled = True
    token = settings.bearer_token.get_secret_value()
    async with connect(
        settings.websocket_url,
        origin=settings.origin,
        additional_headers={"Authorization": f"Bearer {token}"},
        compression=None,
        open_timeout=settings.initial_message_timeout_seconds,
        close_timeout=5,
        ping_interval=20,
        ping_timeout=20,
        max_size=settings.max_message_bytes,
        max_queue=8,
        logger=transport_logger,
    ) as websocket:
        yield websocket


class CaptionOutcome(StrEnum):
    applied = "applied"
    duplicate = "duplicate"
    blocked = "blocked"
    expired = "expired"
    conflict = "conflict"


class CloudCaptionApplier:
    def __init__(
        self,
        display: DisplayAdapter,
        *,
        now: Callable[[], datetime],
        cache_size: int,
    ) -> None:
        self.display = display
        self.now = now
        self.cache_size = cache_size
        self._applied: OrderedDict[UUID, str] = OrderedDict()
        self._lock = asyncio.Lock()

    @staticmethod
    def _fingerprint(caption: CloudCaption) -> str:
        content = {
            "client_message_id": str(caption.client_message_id),
            "text": caption.text,
            "locale": caption.locale,
            "expires_at": caption.expires_at.isoformat(),
        }
        return json.dumps(content, ensure_ascii=False, separators=(",", ":"), sort_keys=True)

    async def apply(self, caption: CloudCaption) -> CaptionOutcome:
        fingerprint = self._fingerprint(caption)
        async with self._lock:
            cached = self._applied.get(caption.id)
            if cached is not None:
                if cached != fingerprint:
                    return CaptionOutcome.conflict
                self._applied.move_to_end(caption.id)
                return CaptionOutcome.duplicate

            now = self.now()
            if caption.expires_at <= now:
                return CaptionOutcome.expired
            current = await self.display.current(now)
            if current is not None and current.mode is DisplayMode.emergency:
                return CaptionOutcome.blocked
            await self.display.render(
                mode=DisplayMode.caption,
                text=caption.text,
                language=caption.locale,
                correlation_id=str(caption.id),
                expires_at=caption.expires_at,
                now=now,
            )
            self._applied[caption.id] = fingerprint
            while len(self._applied) > self.cache_size:
                self._applied.popitem(last=False)
            return CaptionOutcome.applied


class CloudDeviceRelay:
    def __init__(
        self,
        *,
        settings: CloudRelaySettings,
        runtime: EdgeRuntime,
        connector: CloudConnector = connect_cloud,
        monotonic_clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.settings = settings
        self.runtime = runtime
        self.connector = connector
        self.monotonic_clock = monotonic_clock
        self.caption_applier = CloudCaptionApplier(
            runtime.display,
            now=runtime.now,
            cache_size=settings.caption_cache_size,
        )
        self._sequence = 0
        self._sequence_lock = asyncio.Lock()
        self._pending: OrderedDict[UUID, CloudCaption] = OrderedDict()
        self._task: asyncio.Task[None] | None = None
        self._stop = asyncio.Event()

    async def start(self) -> None:
        if self._task is not None:
            return
        self._stop.clear()
        self._task = asyncio.create_task(self._run_forever(), name="fingerspeak-cloud-relay")

    async def stop(self) -> None:
        self._stop.set()
        task = self._task
        self._task = None
        if task is not None:
            task.cancel()
            with suppress(asyncio.CancelledError):
                await task

    async def _sequence_floor(self, value: int) -> None:
        async with self._sequence_lock:
            self._sequence = max(self._sequence, value)

    async def _next_sequence(self) -> int:
        async with self._sequence_lock:
            self._sequence += 1
            return self._sequence

    @staticmethod
    def _camera_status(status: DeviceStatusPayload) -> CloudCameraStatus:
        if status.camera_status is CameraStatus.off:
            return "off"
        if status.camera_status in {CameraStatus.error, CameraStatus.degraded}:
            return "error"
        if status.camera_status is CameraStatus.starting:
            return "active"
        return "active" if status.tracking_status is TrackingStatus.tracking else "ready"

    @staticmethod
    def _display_status(status: DeviceStatusPayload) -> CloudDisplayStatus:
        if not status.display_connected:
            return "off"
        return "active" if status.active_display is not None else "ready"

    @staticmethod
    def _percent(value: float | None) -> int | None:
        return None if value is None else round(value)

    async def telemetry_message(self) -> CloudTelemetry:
        status = (await self.runtime.status_message()).payload
        return CloudTelemetry(
            sequence=await self._next_sequence(),
            observed_at=self.runtime.now(),
            pi_battery_percent=self._percent(status.pi_battery_percent),
            wheelchair_battery_percent=self._percent(status.wheelchair_battery_percent),
            camera_status=self._camera_status(status),
            display_status=self._display_status(status),
            transport=self.settings.transport,
        )

    async def _send_model(self, socket: CloudSocket, message: BaseModel) -> None:
        raw = message.model_dump_json()
        if len(raw.encode("utf-8")) > self.settings.max_message_bytes:
            raise ValueError("outbound cloud relay message exceeds configured size")
        await socket.send(raw)

    async def _ack_caption(self, socket: CloudSocket, caption_id: UUID) -> None:
        await self._send_model(socket, CloudCaptionAck(caption_id=caption_id))

    async def _apply_caption(self, socket: CloudSocket, caption: CloudCaption) -> None:
        if caption.device_id != self.settings.device_id:
            return
        outcome = await self.caption_applier.apply(caption)
        if outcome in {CaptionOutcome.applied, CaptionOutcome.duplicate}:
            self._pending.pop(caption.id, None)
            await self._ack_caption(socket, caption.id)
        elif outcome is CaptionOutcome.blocked:
            self._pending[caption.id] = caption
            while len(self._pending) > self.settings.caption_cache_size:
                self._pending.popitem(last=False)
        else:
            self._pending.pop(caption.id, None)

    async def _flush_pending(self, socket: CloudSocket) -> None:
        for caption in list(self._pending.values()):
            await self._apply_caption(socket, caption)

    async def handle_inbound(self, socket: CloudSocket, raw: str | bytes) -> None:
        if not isinstance(raw, str) or len(raw.encode("utf-8")) > self.settings.max_message_bytes:
            raise ValueError("cloud relay accepts only bounded text JSON")
        try:
            message = CLOUD_INBOUND_ADAPTER.validate_json(raw)
        except ValidationError as exc:
            raise ValueError("invalid cloud device message") from exc

        if isinstance(message, CloudStatus):
            if message.last_state is not None:
                await self._sequence_floor(message.last_state.sequence)
            if message.sequence is not None:
                await self._sequence_floor(message.sequence)
        elif isinstance(message, CloudTelemetryRejected):
            await self._sequence_floor(message.last_sequence)
        elif isinstance(message, CloudCaptionMessage):
            await self._apply_caption(socket, message.caption)

    async def _telemetry_loop(self, socket: CloudSocket) -> None:
        while True:
            await self._flush_pending(socket)
            await self._send_model(socket, await self.telemetry_message())
            await asyncio.sleep(self.settings.telemetry_interval_seconds)

    async def run_connection(self, socket: CloudSocket) -> None:
        initial = await asyncio.wait_for(
            socket.recv(), timeout=self.settings.initial_message_timeout_seconds
        )
        await self.handle_inbound(socket, initial)
        telemetry_task = asyncio.create_task(self._telemetry_loop(socket))
        try:
            while True:
                await self.handle_inbound(socket, await socket.recv())
        finally:
            telemetry_task.cancel()
            with suppress(asyncio.CancelledError):
                await telemetry_task

    async def _wait_or_stop(self, delay: float) -> None:
        try:
            await asyncio.wait_for(self._stop.wait(), timeout=delay)
        except TimeoutError:
            pass

    async def _run_forever(self) -> None:
        delays = bounded_backoff(self.settings)
        delay = next(delays)
        while not self._stop.is_set():
            connected_at = self.monotonic_clock()
            try:
                async with self.connector(self.settings) as socket:
                    await self.run_connection(socket)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                # Log only the exception class: handshake errors may contain request metadata.
                logger.warning("Cloud device relay disconnected (%s).", type(exc).__name__)
            duration = self.monotonic_clock() - connected_at
            if duration >= self.settings.stable_connection_seconds:
                delays = bounded_backoff(self.settings)
                delay = next(delays)
            await self._wait_or_stop(delay)
            delay = next(delays)
