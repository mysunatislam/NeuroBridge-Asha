from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum
from typing import Protocol, runtime_checkable


class CameraStatus(StrEnum):
    off = "off"
    starting = "starting"
    ready = "ready"
    degraded = "degraded"
    error = "error"


class TrackingStatus(StrEnum):
    idle = "idle"
    tracking = "tracking"
    lost = "lost"
    paused = "paused"
    error = "error"


class DisplayMode(StrEnum):
    caption = "caption"
    emergency = "emergency"


@dataclass(frozen=True, slots=True)
class DisplayMessage:
    mode: DisplayMode
    text: str
    language: str
    correlation_id: str | None
    expires_at: datetime | None
    updated_at: datetime
    revision: int


@dataclass(frozen=True, slots=True)
class TelemetrySample:
    tracking_status: TrackingStatus
    pi_battery_percent: float | None = None
    wheelchair_battery_percent: float | None = None


@runtime_checkable
class CameraAdapter(Protocol):
    async def start(self) -> None: ...

    async def stop(self) -> None: ...

    async def status(self) -> CameraStatus: ...


@runtime_checkable
class DisplayAdapter(Protocol):
    async def start(self) -> None: ...

    async def stop(self) -> None: ...

    async def is_connected(self) -> bool: ...

    async def current(self, now: datetime) -> DisplayMessage | None: ...

    async def render(
        self,
        *,
        mode: DisplayMode,
        text: str,
        language: str,
        correlation_id: str | None,
        expires_at: datetime | None,
        now: datetime,
    ) -> DisplayMessage: ...


@runtime_checkable
class TelemetryAdapter(Protocol):
    async def start(self) -> None: ...

    async def stop(self) -> None: ...

    async def sample(self) -> TelemetrySample: ...
