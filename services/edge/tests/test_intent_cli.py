from __future__ import annotations

from fingerspeak_edge.adapters.mediapipe_face_intent import (
    MediaPipePicamera2FaceIntentDetector,
)
from fingerspeak_edge.adapters.picamera2_camera import Picamera2Camera
from fingerspeak_edge.cli import build_parser, build_runtime, resolve_face_model_path
from tests.helpers import PAIRING_CODE


def test_camera_alias_selects_dependency_guarded_mediapipe_monitor() -> None:
    args = build_parser().parse_args(
        ["--camera", "picamera2", "--intent-detector", "mediapipe"]
    )

    runtime = build_runtime(args, PAIRING_CODE)

    assert isinstance(runtime.camera, Picamera2Camera)
    assert runtime.intent_monitor is not None
    assert isinstance(
        runtime.intent_monitor.detector, MediaPipePicamera2FaceIntentDetector
    )
    assert runtime.intent_monitor.detector.model_path == resolve_face_model_path(None)


def test_mediapipe_detector_requires_picamera2_adapter() -> None:
    args = build_parser().parse_args(["--intent-detector", "mediapipe"])

    try:
        build_runtime(args, PAIRING_CODE)
    except ValueError as exc:
        assert str(exc) == "--intent-detector mediapipe requires --adapter picamera2"
    else:
        raise AssertionError("invalid camera/detector combination was accepted")
