from __future__ import annotations

import pytest
from fingerspeak_edge.adapters.picamera_legacy_camera import PicameraLegacyCamera


@pytest.mark.asyncio
async def test_picamera_is_imported_only_when_adapter_starts(monkeypatch) -> None:
    def unavailable(_: str):
        raise ModuleNotFoundError("picamera")

    monkeypatch.setattr(
        "fingerspeak_edge.adapters.picamera_legacy_camera.importlib.import_module", unavailable
    )
    camera = PicameraLegacyCamera()

    with pytest.raises(RuntimeError, match="python3-picamera"):
        await camera.start()

    assert await camera.status() == "error"
