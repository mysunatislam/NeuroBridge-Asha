from __future__ import annotations

import importlib
from typing import Any

from fingerspeak_edge.adapters.base import CameraStatus


class Picamera2Camera:
    """Lazy Raspberry Pi camera adapter.

    Importing this module is safe on non-Pi systems. The OS-provided ``picamera2`` package is
    imported only when ``start`` runs.
    """

    def __init__(self, *, width: int = 640, height: int = 480) -> None:
        self.width = width
        self.height = height
        self._camera: Any | None = None
        self._status = CameraStatus.off

    async def start(self) -> None:
        self._status = CameraStatus.starting
        try:
            module = importlib.import_module("picamera2")
            camera = module.Picamera2()
            configuration = camera.create_preview_configuration(
                main={"size": (self.width, self.height), "format": "RGB888"}
            )
            camera.configure(configuration)
            camera.start()
        except Exception as exc:
            self._status = CameraStatus.error
            raise RuntimeError(
                "Picamera2 could not start. Install Raspberry Pi OS package "
                "python3-picamera2 and verify the camera with rpicam-hello."
            ) from exc
        self._camera = camera
        self._status = CameraStatus.ready

    async def stop(self) -> None:
        camera = self._camera
        self._camera = None
        if camera is not None:
            camera.stop()
            close = getattr(camera, "close", None)
            if callable(close):
                close()
        self._status = CameraStatus.off

    async def status(self) -> CameraStatus:
        return self._status

    def capture_frame(self) -> Any:
        if self._camera is None or self._status is not CameraStatus.ready:
            raise RuntimeError("Camera is not ready.")
        return self._camera.capture_array("main")
