from __future__ import annotations

import asyncio
import logging
from datetime import datetime

from fingerspeak_edge.adapters.base import (
    CameraStatus,
    DisplayMessage,
    DisplayMode,
    TelemetrySample,
    TrackingStatus,
)

logger = logging.getLogger(__name__)


class SimulatedCamera:
    """Deterministic camera lifecycle with no image or Raspberry Pi dependency."""

    def __init__(self) -> None:
        self._status = CameraStatus.off

    async def start(self) -> None:
        self._status = CameraStatus.starting
        await asyncio.sleep(0)
        self._status = CameraStatus.ready

    async def stop(self) -> None:
        self._status = CameraStatus.off

    async def status(self) -> CameraStatus:
        return self._status


class SimulatedDisplay:
    """Plain-text display sink used by the CLI demo and unit tests."""

    def __init__(self) -> None:
        self._connected = False
        self._current: DisplayMessage | None = None
        self._revision = 0
        self.history: list[DisplayMessage] = []
        self._lock = asyncio.Lock()

    async def start(self) -> None:
        self._connected = True

    async def stop(self) -> None:
        self._connected = False

    async def is_connected(self) -> bool:
        return self._connected

    async def current(self, now: datetime) -> DisplayMessage | None:
        async with self._lock:
            if self._current is not None and self._current.expires_at is not None:
                if self._current.expires_at <= now:
                    self._current = None
            return self._current

    async def render(
        self,
        *,
        mode: DisplayMode,
        text: str,
        language: str,
        correlation_id: str | None,
        expires_at: datetime | None,
        now: datetime,
    ) -> DisplayMessage:
        async with self._lock:
            self._revision += 1
            message = DisplayMessage(
                mode=mode,
                text=text,
                language=language,
                correlation_id=correlation_id,
                expires_at=expires_at,
                updated_at=now,
                revision=self._revision,
            )
            self._current = message
            self.history.append(message)
        logger.info("simulated display [%s]: %s", mode.value, text)
        return message


class SimulatedTelemetry:
    def __init__(
        self,
        *,
        tracking_status: TrackingStatus = TrackingStatus.tracking,
        pi_battery_percent: float | None = None,
        wheelchair_battery_percent: float | None = None,
    ) -> None:
        self.tracking_status = tracking_status
        self.pi_battery_percent = pi_battery_percent
        self.wheelchair_battery_percent = wheelchair_battery_percent
        self._running = False

    async def start(self) -> None:
        self._running = True

    async def stop(self) -> None:
        self._running = False

    async def sample(self) -> TelemetrySample:
        return TelemetrySample(
            tracking_status=self.tracking_status if self._running else TrackingStatus.paused,
            pi_battery_percent=self.pi_battery_percent,
            wheelchair_battery_percent=self.wheelchair_battery_percent,
        )
