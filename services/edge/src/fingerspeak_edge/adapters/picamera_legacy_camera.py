from __future__ import annotations

import importlib
from typing import Any

from fingerspeak_edge.adapters.base import CameraStatus


class PicameraLegacyCamera:
    """Lazy Raspberry Pi legacy camera adapter using the classic ``picamera`` library (MMAL).

    Compatible with Raspberry Pi Model B / B+ / 2 / 3 on Raspberry Pi OS Buster or Bullseye
    where the legacy Broadcom camera stack (MMAL) is enabled via raspi-config.
    """

    def __init__(self, *, width: int = 640, height: int = 480, framerate: int = 30) -> None:
        self.width = width
        self.height = height
        self.framerate = framerate
        self._camera: Any | None = None
        self._status = CameraStatus.off

    async def start(self) -> None:
        self._status = CameraStatus.starting
        try:
            module = importlib.import_module("picamera")
            camera = module.PiCamera(
                resolution=(self.width, self.height),
                framerate=self.framerate,
            )
            self._camera = camera
            self._status = CameraStatus.ready
        except Exception as exc:
            self._status = CameraStatus.error
            raise RuntimeError(
                "Legacy picamera could not start. Ensure the camera is enabled in "
                "raspi-config (Interfacing Options -> Camera) and python3-picamera is installed."
            ) from exc

    async def stop(self) -> None:
        camera = self._camera
        self._camera = None
        if camera is not None:
            close = getattr(camera, "close", None)
            if callable(close):
                close()
        self._status = CameraStatus.off

    async def status(self) -> CameraStatus:
        return self._status

    def capture_frame(self) -> Any:
        if self._camera is None or self._status is not CameraStatus.ready:
            raise RuntimeError("Camera is not ready.")
        import numpy as np

        output = np.empty((self.height, self.width, 3), dtype=np.uint8)
        self._camera.capture(output, "rgb", use_video_port=True)
        return output
