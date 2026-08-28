from __future__ import annotations

from dataclasses import fields
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest

from fingerspeak_edge.adapters.mediapipe_face_intent import (
    MediaPipePicamera2FaceIntentDetector,
    extract_face_movement_sample,
)


def category(name: str, score: float) -> SimpleNamespace:
    return SimpleNamespace(category_name=name, score=score)


def face_result(
    categories: list[SimpleNamespace], landmarks: list[SimpleNamespace] | None = None
) -> SimpleNamespace:
    return SimpleNamespace(
        face_blendshapes=[categories],
        face_landmarks=[landmarks or make_landmarks()],
    )


def make_landmarks() -> list[SimpleNamespace]:
    return [SimpleNamespace(x=0.5, y=0.5) for _ in range(478)]


def test_extracts_only_bounded_intent_scores_from_blendshapes() -> None:
    result = face_result(
        [
            category("eyeBlinkLeft", 0.9),
            category("eyeBlinkRight", 0.8),
            category("eyeLookOutLeft", 0.1),
            category("eyeLookInRight", 0.2),
            category("eyeLookInLeft", 0.8),
            category("eyeLookOutRight", 0.6),
            category("browInnerUp", 0.6),
            category("browOuterUpLeft", 0.3),
            category("browOuterUpRight", 0.9),
            category("jawOpen", 0.7),
        ]
    )

    sample = extract_face_movement_sample(result)

    assert sample.face_present is True
    assert sample.blink == pytest.approx(0.8)
    assert sample.gaze_horizontal == pytest.approx(0.55)
    assert sample.eyebrows_up == pytest.approx(0.6)
    assert sample.mouth_open == pytest.approx(0.7)
    assert {field.name for field in fields(sample)} == {
        "face_present",
        "blink",
        "gaze_horizontal",
        "eyebrows_up",
        "mouth_open",
    }


def test_uses_iris_landmarks_when_gaze_blendshapes_are_absent() -> None:
    landmarks = make_landmarks()
    landmarks[33].x = 0.2
    landmarks[133].x = 0.4
    landmarks[468].x = 0.38
    landmarks[362].x = 0.6
    landmarks[263].x = 0.8
    landmarks[473].x = 0.78

    sample = extract_face_movement_sample(
        face_result(
            [
                category("eyeBlinkLeft", 0.1),
                category("eyeBlinkRight", 0.1),
                category("browInnerUp", 0.1),
                category("jawOpen", 0.1),
            ],
            landmarks,
        )
    )

    assert sample.gaze_horizontal == pytest.approx(-0.8)


def test_no_face_returns_an_incomplete_media_free_sample() -> None:
    sample = extract_face_movement_sample(
        SimpleNamespace(face_blendshapes=[], face_landmarks=[])
    )

    assert sample.face_present is False
    assert sample.complete() is False
    assert sample.blink is None
    assert sample.gaze_horizontal is None


class FakeArray:
    ndim = 3
    shape = (480, 640, 3)


class FakeNumpy:
    uint8 = "uint8"

    def __init__(self) -> None:
        self.array = FakeArray()
        self.asarray_inputs: list[Any] = []

    def asarray(self, value: Any) -> FakeArray:
        self.asarray_inputs.append(value)
        return self.array

    def ascontiguousarray(self, value: FakeArray, *, dtype: Any) -> FakeArray:
        assert value is self.array
        assert dtype == self.uint8
        return value


class FakeCamera:
    def __init__(self) -> None:
        self.frame = object()
        self.capture_count = 0

    def capture_frame(self) -> object:
        self.capture_count += 1
        return self.frame


def make_fake_mediapipe(result: SimpleNamespace) -> tuple[SimpleNamespace, type[Any]]:
    class FakeImage:
        def __init__(self, *, image_format: Any, data: Any) -> None:
            self.image_format = image_format
            self.data = data

    class FakeLandmarker:
        options: Any = None
        timestamps: list[int] = []
        closed = False

        @classmethod
        def create_from_options(cls, options: Any) -> type[FakeLandmarker]:
            cls.options = options
            return cls

        @classmethod
        def detect_for_video(cls, image: Any, timestamp_ms: int) -> SimpleNamespace:
            assert image.image_format == "srgb"
            cls.timestamps.append(timestamp_ms)
            return result

        @classmethod
        def close(cls) -> None:
            cls.closed = True

    class FakeOptions(SimpleNamespace):
        def __init__(self, **kwargs: Any) -> None:
            super().__init__(**kwargs)

    module = SimpleNamespace(
        Image=FakeImage,
        ImageFormat=SimpleNamespace(SRGB="srgb"),
        tasks=SimpleNamespace(
            BaseOptions=FakeOptions,
            vision=SimpleNamespace(
                RunningMode=SimpleNamespace(VIDEO="video"),
                FaceLandmarkerOptions=FakeOptions,
                FaceLandmarker=FakeLandmarker,
            ),
        ),
    )
    return module, FakeLandmarker


@pytest.mark.asyncio
async def test_adapter_lazily_runs_video_mode_with_strict_options(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    model = tmp_path / "face_landmarker.task"
    model.write_bytes(b"fake model for dependency-boundary test")
    camera = FakeCamera()
    numpy = FakeNumpy()
    mediapipe, landmarker = make_fake_mediapipe(
        face_result(
            [
                category("eyeBlinkLeft", 0.1),
                category("eyeBlinkRight", 0.1),
                category("eyeLookOutLeft", 0.1),
                category("eyeLookInRight", 0.1),
                category("eyeLookInLeft", 0.1),
                category("eyeLookOutRight", 0.1),
                category("browInnerUp", 0.1),
                category("jawOpen", 0.1),
            ]
        )
    )

    def import_module(name: str) -> Any:
        return {"mediapipe": mediapipe, "numpy": numpy}[name]

    monkeypatch.setattr(
        "fingerspeak_edge.adapters.mediapipe_face_intent.importlib.import_module",
        import_module,
    )
    monkeypatch.setattr(
        "fingerspeak_edge.adapters.mediapipe_face_intent.time.monotonic",
        lambda: 100.0,
    )
    detector = MediaPipePicamera2FaceIntentDetector(
        camera,
        model_path=model,
        expected_model_sha256=None,
    )

    await detector.start()
    first = await detector.sample()
    second = await detector.sample()
    await detector.stop()

    assert first.complete() and second.complete()
    assert camera.capture_count == 2
    assert numpy.asarray_inputs == [camera.frame, camera.frame]
    assert landmarker.options.running_mode == "video"
    assert landmarker.options.num_faces == 1
    assert landmarker.options.output_face_blendshapes is True
    assert landmarker.options.output_facial_transformation_matrixes is False
    assert landmarker.timestamps == [100_000, 100_001]
    assert landmarker.closed is True


@pytest.mark.asyncio
async def test_adapter_fails_clearly_when_optional_dependency_is_missing(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    model = tmp_path / "face_landmarker.task"
    model.write_bytes(b"test model")

    def unavailable(_: str) -> Any:
        raise ModuleNotFoundError("mediapipe")

    monkeypatch.setattr(
        "fingerspeak_edge.adapters.mediapipe_face_intent.importlib.import_module",
        unavailable,
    )
    detector = MediaPipePicamera2FaceIntentDetector(
        FakeCamera(), model_path=model, expected_model_sha256=None
    )

    with pytest.raises(RuntimeError, match="optional vision dependencies"):
        await detector.start()


@pytest.mark.asyncio
async def test_adapter_rejects_a_model_that_is_not_the_pinned_official_asset(
    tmp_path: Path,
) -> None:
    model = tmp_path / "face_landmarker.task"
    model.write_bytes(b"not the official model")
    detector = MediaPipePicamera2FaceIntentDetector(FakeCamera(), model_path=model)

    with pytest.raises(RuntimeError, match="checksum"):
        await detector.start()
