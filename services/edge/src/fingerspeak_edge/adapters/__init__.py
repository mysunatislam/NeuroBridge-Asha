"""Hardware boundaries for camera, display, and telemetry adapters."""

from fingerspeak_edge.adapters.base import (
    CameraAdapter,
    CameraStatus,
    DisplayAdapter,
    DisplayMessage,
    DisplayMode,
    TelemetryAdapter,
    TelemetrySample,
    TrackingStatus,
)
from fingerspeak_edge.adapters.simulated import (
    SimulatedCamera,
    SimulatedDisplay,
    SimulatedTelemetry,
)

__all__ = [
    "CameraAdapter",
    "CameraStatus",
    "DisplayAdapter",
    "DisplayMessage",
    "DisplayMode",
    "SimulatedCamera",
    "SimulatedDisplay",
    "SimulatedTelemetry",
    "TelemetryAdapter",
    "TelemetrySample",
    "TrackingStatus",
]
