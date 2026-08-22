from __future__ import annotations

import pytest

from fingerspeak_edge.adapters.picamera2_camera import Picamera2Camera


@pytest.mark.asyncio
async def test_picamera2_is_imported_only_when_adapter_starts(monkeypatch) -> None:
    def unavailable(_: str):
        raise ModuleNotFoundError("picamera2")

    monkeypatch.setattr(
        "fingerspeak_edge.adapters.picamera2_camera.importlib.import_module", unavailable
    )
    camera = Picamera2Camera()

    with pytest.raises(RuntimeError, match="python3-picamera2"):
        await camera.start()

    assert await camera.status() == "error"
