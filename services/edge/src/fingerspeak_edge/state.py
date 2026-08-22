from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import re
import secrets
import time
from collections import OrderedDict
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from uuid import UUID, uuid4

from fingerspeak_edge.adapters import (
    CameraAdapter,
    DisplayAdapter,
    DisplayMode,
    TelemetryAdapter,
)
from fingerspeak_edge.protocol import (
    CaptionSet,
    CommandAck,
    CommandAckPayload,
    DeviceStatus,
    DeviceStatusPayload,
    EmergencyDisplay,
    Heartbeat,
    PairingAuthenticate,
    PairingAuthenticated,
    PairingAuthenticatedPayload,
    ProtocolError,
    ProtocolErrorPayload,
    ServerEnvelope,
    StatusGet,
)


class ProtocolViolation(ValueError):
    def __init__(self, code: str, detail: str, ref_message_id: UUID | None = None) -> None:
        super().__init__(detail)
        self.code = code
        self.detail = detail
        self.ref_message_id = ref_message_id


@dataclass(frozen=True, slots=True)
class AuthenticationResult:
    phone_id: str
    device_credential: str | None


class PairingAuthority:
    """Consume a one-time pairing code and retain only credential digests in memory."""

    def __init__(self, pairing_code: str, *, device_credential: str | None = None) -> None:
        if len(pairing_code) < 16:
            raise ValueError("pairing code must contain at least 16 characters")
        self._pairing_digest: bytes | None = self._digest(pairing_code)
        self._device_digest = self._digest(device_credential) if device_credential else None
        self._lock = asyncio.Lock()

    @staticmethod
    def _digest(value: str) -> bytes:
        return hashlib.sha256(value.encode("utf-8")).digest()

    async def authenticate(self, request: PairingAuthenticate) -> AuthenticationResult:
        candidate = self._digest(request.payload.credential)
        async with self._lock:
            if request.payload.credential_kind == "pairing_code":
                if self._pairing_digest is None or not hmac.compare_digest(
                    candidate, self._pairing_digest
                ):
                    raise ProtocolViolation(
                        "authentication_failed",
                        "The pairing code is invalid or has already been consumed.",
                        request.message_id,
                    )
                credential = secrets.token_urlsafe(32)
                self._device_digest = self._digest(credential)
                self._pairing_digest = None
                return AuthenticationResult(request.payload.phone_id, credential)

            if self._device_digest is None or not hmac.compare_digest(
                candidate, self._device_digest
            ):
                raise ProtocolViolation(
                    "authentication_failed",
                    "The device credential is invalid.",
                    request.message_id,
                )
            return AuthenticationResult(request.payload.phone_id, None)


@dataclass(frozen=True, slots=True)
class EdgeSettings:
    device_id: str
    max_message_bytes: int = 4_096
    authentication_timeout_seconds: float = 5.0
    heartbeat_interval_seconds: float = 5.0
    heartbeat_timeout_seconds: float = 20.0
    status_interval_seconds: float = 5.0
    max_clock_skew_seconds: float = 300.0
    idempotency_cache_size: int = 256

    def __post_init__(self) -> None:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,79}", self.device_id):
            raise ValueError("device_id must be a bounded FingerSpeak short key")
        if not 512 <= self.max_message_bytes <= 65_536:
            raise ValueError("max_message_bytes must be between 512 and 65536")
        if self.heartbeat_interval_seconds <= 0:
            raise ValueError("heartbeat_interval_seconds must be positive")
        if self.heartbeat_timeout_seconds <= self.heartbeat_interval_seconds:
            raise ValueError("heartbeat timeout must exceed the heartbeat interval")
        if self.status_interval_seconds <= 0:
            raise ValueError("status_interval_seconds must be positive")
        if self.idempotency_cache_size < 1:
            raise ValueError("idempotency_cache_size must be positive")


@dataclass(frozen=True, slots=True)
class CachedCommand:
    fingerprint: str
    payload: CommandAckPayload


class EdgeRuntime:
    def __init__(
        self,
        *,
        settings: EdgeSettings,
        pairing: PairingAuthority,
        camera: CameraAdapter,
        display: DisplayAdapter,
        telemetry: TelemetryAdapter,
        wall_clock: Callable[[], datetime] | None = None,
        monotonic_clock: Callable[[], float] | None = None,
    ) -> None:
        self.settings = settings
        self.pairing = pairing
        self.camera = camera
        self.display = display
        self.telemetry = telemetry
        self._wall_clock = wall_clock or (lambda: datetime.now(UTC))
        self._monotonic = monotonic_clock or time.monotonic
        self._connections: dict[UUID, float] = {}
        self._connections_lock = asyncio.Lock()
        self._sequence = 0
        self._sequence_lock = asyncio.Lock()
        self._command_cache: OrderedDict[UUID, CachedCommand] = OrderedDict()
        self._command_lock = asyncio.Lock()
        self._started = False

    async def start(self) -> None:
        await self.display.start()
        await self.telemetry.start()
        try:
            await self.camera.start()
        except Exception:
            await self.telemetry.stop()
            await self.display.stop()
            raise
        self._started = True

    async def stop(self) -> None:
        self._started = False
        await self.camera.stop()
        await self.telemetry.stop()
        await self.display.stop()

    @property
    def started(self) -> bool:
        return self._started

    def now(self) -> datetime:
        return self._wall_clock()

    async def _next_sequence(self) -> int:
        async with self._sequence_lock:
            self._sequence += 1
            return self._sequence

    async def _envelope_fields(self) -> dict[str, object]:
        return {
            "message_id": uuid4(),
            "device_id": self.settings.device_id,
            "sent_at": self.now(),
            "sequence": await self._next_sequence(),
        }

    def validate_target_and_time(
        self,
        message: PairingAuthenticate | Heartbeat | StatusGet | CaptionSet | EmergencyDisplay,
    ) -> None:
        if message.device_id != self.settings.device_id:
            raise ProtocolViolation(
                "wrong_device",
                "The message targets a different device.",
                message.message_id,
            )
        skew = abs((self.now() - message.sent_at).total_seconds())
        if skew > self.settings.max_clock_skew_seconds:
            raise ProtocolViolation(
                "stale_message",
                "The message timestamp is outside the permitted clock-skew window.",
                message.message_id,
            )

    async def authenticate(
        self, request: PairingAuthenticate
    ) -> tuple[UUID, PairingAuthenticated]:
        self.validate_target_and_time(request)
        result = await self.pairing.authenticate(request)
        connection_id = uuid4()
        async with self._connections_lock:
            self._connections[connection_id] = self._monotonic()
        response = PairingAuthenticated(
            **await self._envelope_fields(),
            payload=PairingAuthenticatedPayload(
                connection_id=connection_id,
                phone_id=result.phone_id,
                device_credential=result.device_credential,
                heartbeat_interval_seconds=self.settings.heartbeat_interval_seconds,
                heartbeat_timeout_seconds=self.settings.heartbeat_timeout_seconds,
                max_message_bytes=self.settings.max_message_bytes,
            ),
        )
        return connection_id, response

    async def touch(self, connection_id: UUID) -> None:
        async with self._connections_lock:
            self._connections[connection_id] = self._monotonic()

    async def disconnect(self, connection_id: UUID) -> None:
        async with self._connections_lock:
            self._connections.pop(connection_id, None)

    async def _phone_connected(self) -> bool:
        threshold = self._monotonic() - self.settings.heartbeat_timeout_seconds
        async with self._connections_lock:
            stale = [key for key, last_seen in self._connections.items() if last_seen < threshold]
            for key in stale:
                self._connections.pop(key, None)
            return bool(self._connections)

    async def status_message(self) -> DeviceStatus:
        now = self.now()
        current = await self.display.current(now)
        telemetry = await self.telemetry.sample()
        payload = DeviceStatusPayload(
            phone_connected=await self._phone_connected(),
            display_connected=await self.display.is_connected(),
            camera_status=await self.camera.status(),
            tracking_status=telemetry.tracking_status,
            pi_battery_percent=telemetry.pi_battery_percent,
            wheelchair_battery_percent=telemetry.wheelchair_battery_percent,
            active_display=current.mode if current else None,
            display_revision=current.revision if current else None,
        )
        return DeviceStatus(**await self._envelope_fields(), payload=payload)

    @staticmethod
    def _fingerprint(command: CaptionSet | EmergencyDisplay) -> str:
        content = {
            "device_id": command.device_id,
            "type": command.type,
            "payload": command.payload.model_dump(mode="json"),
        }
        return json.dumps(content, ensure_ascii=False, separators=(",", ":"), sort_keys=True)

    async def _display_command_payload(
        self, command: CaptionSet | EmergencyDisplay
    ) -> CommandAckPayload:
        now = self.now()
        expires_at = command.payload.expires_at
        if expires_at is not None and expires_at <= now:
            return CommandAckPayload(
                command_id=command.message_id,
                command_type=command.type,
                accepted=False,
                detail="The display command has already expired.",
            )

        current = await self.display.current(now)
        if isinstance(command, CaptionSet) and current is not None:
            if current.mode is DisplayMode.emergency:
                return CommandAckPayload(
                    command_id=command.message_id,
                    command_type=command.type,
                    accepted=False,
                    detail="An active emergency display has priority over routine captions.",
                    display_revision=current.revision,
                )

        if isinstance(command, CaptionSet):
            mode = DisplayMode.caption
            correlation_id = command.payload.correlation_id
        else:
            mode = DisplayMode.emergency
            correlation_id = command.payload.alert_id

        rendered = await self.display.render(
            mode=mode,
            text=command.payload.text,
            language=command.payload.language,
            correlation_id=correlation_id,
            expires_at=expires_at,
            now=now,
        )
        return CommandAckPayload(
            command_id=command.message_id,
            command_type=command.type,
            accepted=True,
            detail="Display updated.",
            display_revision=rendered.revision,
        )

    async def command_ack(
        self,
        connection_id: UUID,
        command: Heartbeat | StatusGet | CaptionSet | EmergencyDisplay,
    ) -> CommandAck:
        self.validate_target_and_time(command)
        await self.touch(connection_id)

        if isinstance(command, (Heartbeat, StatusGet)):
            detail = (
                "Heartbeat received."
                if isinstance(command, Heartbeat)
                else "Status requested."
            )
            payload = CommandAckPayload(
                command_id=command.message_id,
                command_type=command.type,
                accepted=True,
                detail=detail,
            )
            return CommandAck(**await self._envelope_fields(), payload=payload)

        fingerprint = self._fingerprint(command)
        async with self._command_lock:
            cached = self._command_cache.get(command.message_id)
            if cached is not None:
                if cached.fingerprint != fingerprint:
                    raise ProtocolViolation(
                        "message_id_reused",
                        "A message ID cannot be reused for different command content.",
                        command.message_id,
                    )
                duplicate = cached.payload.model_copy(
                    update={
                        "duplicate": True,
                        "detail": "Duplicate command; prior result replayed.",
                    }
                )
                self._command_cache.move_to_end(command.message_id)
                return CommandAck(**await self._envelope_fields(), payload=duplicate)

            payload = await self._display_command_payload(command)
            self._command_cache[command.message_id] = CachedCommand(fingerprint, payload)
            while len(self._command_cache) > self.settings.idempotency_cache_size:
                self._command_cache.popitem(last=False)
        return CommandAck(**await self._envelope_fields(), payload=payload)

    async def error_message(self, violation: ProtocolViolation) -> ProtocolError:
        return ProtocolError(
            **await self._envelope_fields(),
            payload=ProtocolErrorPayload(
                code=violation.code,
                detail=violation.detail,
                ref_message_id=violation.ref_message_id,
            ),
        )

    async def validation_error_message(
        self, detail: str, *, ref_message_id: UUID | None = None
    ) -> ProtocolError:
        return await self.error_message(
            ProtocolViolation("invalid_message", detail, ref_message_id)
        )


def server_json(message: ServerEnvelope) -> str:
    return message.model_dump_json()
