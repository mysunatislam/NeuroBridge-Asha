from __future__ import annotations

import asyncio
import hashlib
import importlib
import math
import time
from pathlib import Path
from typing import Any, Protocol

from fingerspeak_edge.intent_monitor import FaceMovementSample

OFFICIAL_FACE_LANDMARKER_SHA256 = (
    "64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff"
)


class FrameCamera(Protocol):
    """The deliberately small camera surface needed by the local detector."""

    def capture_frame(self) -> Any: ...


class MediaPipePicamera2FaceIntentDetector:
    """Local MediaPipe Face Landmarker adapter for an already-started Picamera2 camera.

    Frames and landmarks remain method-local. Only the four bounded movement scores in
    :class:`FaceMovementSample` cross this adapter boundary. This is an intentional-control
    detector; it does not infer emotion, identity, pain, diagnosis, or muscle health.

    ``mediapipe`` and ``numpy`` are imported lazily so importing/running the edge simulator on
    another platform never requires Raspberry Pi vision dependencies.
    """

    def __init__(
        self,
        camera: FrameCamera,
        *,
        model_path: str | Path,
        expected_model_sha256: str | None = OFFICIAL_FACE_LANDMARKER_SHA256,
    ) -> None:
        self._camera = camera
        self._model_path = Path(model_path).expanduser()
        self._expected_model_sha256 = expected_model_sha256
        self._mediapipe: Any | None = None
        self._numpy: Any | None = None
        self._landmarker: Any | None = None
        self._last_timestamp_ms = -1
        self._sample_lock = asyncio.Lock()

    @property
    def model_path(self) -> Path:
        return self._model_path

    async def start(self) -> None:
        if self._landmarker is not None:
            raise RuntimeError("MediaPipe face-intent detector is already running.")
        await asyncio.to_thread(self._start_sync)

    async def stop(self) -> None:
        async with self._sample_lock:
            landmarker = self._landmarker
            self._landmarker = None
            self._mediapipe = None
            self._numpy = None
            self._last_timestamp_ms = -1
            if landmarker is not None:
                await asyncio.to_thread(landmarker.close)

    async def sample(self) -> FaceMovementSample:
        async with self._sample_lock:
            if self._landmarker is None:
                raise RuntimeError("MediaPipe face-intent detector is not running.")
            return await asyncio.to_thread(self._sample_sync)

    def _start_sync(self) -> None:
        model_path = self._model_path.resolve()
        if not model_path.is_file():
            raise RuntimeError(
                "MediaPipe face model was not found. Pass --face-model-path pointing to the "
                "bundled apps/web/public/models/face_landmarker.task file."
            )
        if self._expected_model_sha256 is not None:
            actual = _sha256_file(model_path)
            if actual != self._expected_model_sha256.lower():
                raise RuntimeError(
                    "MediaPipe face model checksum does not match the pinned official model."
                )

        try:
            mediapipe = importlib.import_module("mediapipe")
            numpy = importlib.import_module("numpy")
        except ModuleNotFoundError as exc:
            raise RuntimeError(
                "MediaPipe face intents need the optional vision dependencies. On Raspberry "
                "Pi OS 64-bit, install the edge package with the 'vision' extra."
            ) from exc

        try:
            vision = mediapipe.tasks.vision
            options = vision.FaceLandmarkerOptions(
                base_options=mediapipe.tasks.BaseOptions(
                    model_asset_path=str(model_path)
                ),
                running_mode=vision.RunningMode.VIDEO,
                num_faces=1,
                output_face_blendshapes=True,
                output_facial_transformation_matrixes=False,
            )
            landmarker = vision.FaceLandmarker.create_from_options(options)
        except Exception as exc:
            raise RuntimeError(
                "MediaPipe Face Landmarker could not initialize. Verify the optional vision "
                "dependencies and the pinned face model."
            ) from exc

        self._model_path = model_path
        self._mediapipe = mediapipe
        self._numpy = numpy
        self._landmarker = landmarker
        self._last_timestamp_ms = -1

    def _sample_sync(self) -> FaceMovementSample:
        mediapipe = self._mediapipe
        numpy = self._numpy
        landmarker = self._landmarker
        if mediapipe is None or numpy is None or landmarker is None:
            raise RuntimeError("MediaPipe face-intent detector is not running.")

        # These values are intentionally local and are never retained, serialized, or sent.
        frame = self._camera.capture_frame()
        array = numpy.asarray(frame)
        if getattr(array, "ndim", None) != 3:
            raise RuntimeError("Picamera2 must return a three-dimensional RGB frame.")
        shape = getattr(array, "shape", ())
        if len(shape) != 3 or shape[0] < 1 or shape[1] < 1 or shape[2] < 3:
            raise RuntimeError("Picamera2 returned an invalid RGB frame.")
        if shape[2] > 3:
            array = array[:, :, :3]
        array = numpy.ascontiguousarray(array, dtype=numpy.uint8)
        image = mediapipe.Image(
            image_format=mediapipe.ImageFormat.SRGB,
            data=array,
        )
        timestamp_ms = max(
            self._last_timestamp_ms + 1,
            int(time.monotonic() * 1_000),
        )
        self._last_timestamp_ms = timestamp_ms
        result = landmarker.detect_for_video(image, timestamp_ms)
        return extract_face_movement_sample(result)


def extract_face_movement_sample(result: Any) -> FaceMovementSample:
    """Convert a FaceLandmarker result to bounded movement scores without retaining it."""

    faces = getattr(result, "face_landmarks", None) or ()
    blendshapes = getattr(result, "face_blendshapes", None) or ()
    if not faces and not blendshapes:
        return FaceMovementSample.neutral(face_present=False)

    landmarks = faces[0] if faces else ()
    scores = _blendshape_scores(blendshapes[0]) if blendshapes else {}

    # A deliberate blink requires both eyelids; a one-eye signal is not treated as a blink.
    left_blink = scores.get("eyeBlinkLeft")
    right_blink = scores.get("eyeBlinkRight")
    blink = (
        min(left_blink, right_blink)
        if left_blink is not None and right_blink is not None
        else None
    )

    patient_left = _average_present(
        scores.get("eyeLookOutLeft"), scores.get("eyeLookInRight")
    )
    patient_right = _average_present(
        scores.get("eyeLookInLeft"), scores.get("eyeLookOutRight")
    )
    gaze = (
        _clamp(patient_right - patient_left, -1, 1)
        if patient_left is not None and patient_right is not None
        else _iris_gaze(landmarks)
    )

    eyebrows = _average_present(
        scores.get("browInnerUp"),
        scores.get("browOuterUpLeft"),
        scores.get("browOuterUpRight"),
    )
    mouth = scores.get("jawOpen")
    return FaceMovementSample(
        face_present=True,
        blink=_bounded_or_none(blink),
        gaze_horizontal=_bounded_or_none(gaze, lower=-1),
        eyebrows_up=_bounded_or_none(eyebrows),
        mouth_open=_bounded_or_none(mouth),
    )


def _blendshape_scores(classification: Any) -> dict[str, float]:
    categories = getattr(classification, "categories", classification)
    try:
        iterator = iter(categories)
    except TypeError:
        return {}

    scores: dict[str, float] = {}
    for category in iterator:
        name = getattr(category, "category_name", None)
        if name is None:
            name = getattr(category, "categoryName", None)
        score = getattr(category, "score", None)
        if not isinstance(name, str) or not name or not isinstance(score, (int, float)):
            continue
        numeric = float(score)
        if math.isfinite(numeric):
            scores[name] = max(scores.get(name, 0.0), _clamp(numeric, 0, 1))
    return scores


def _iris_gaze(landmarks: Any) -> float | None:
    # MediaPipe refined face mesh: left/right iris centers 468/473, eye corners below.
    indexes = (33, 133, 362, 263, 468, 473)
    try:
        points = [landmarks[index] for index in indexes]
    except (IndexError, KeyError, TypeError):
        return None
    if any(not _finite_point(point) for point in points):
        return None

    left_ratio = _horizontal_ratio(landmarks[468], landmarks[33], landmarks[133])
    right_ratio = _horizontal_ratio(landmarks[473], landmarks[362], landmarks[263])
    if left_ratio is None or right_ratio is None:
        return None
    iris_ratio = (left_ratio + right_ratio) / 2
    # Negative is the patient's left and positive is the patient's right.
    return _clamp((0.5 - iris_ratio) * 2, -1, 1)


def _horizontal_ratio(point: Any, first_corner: Any, second_corner: Any) -> float | None:
    first = float(first_corner.x)
    second = float(second_corner.x)
    width = abs(first - second)
    if width <= 1e-6:
        return None
    return _clamp((float(point.x) - min(first, second)) / width, 0, 1)


def _finite_point(point: Any) -> bool:
    try:
        return math.isfinite(float(point.x)) and math.isfinite(float(point.y))
    except (AttributeError, TypeError, ValueError):
        return False


def _average_present(*values: float | None) -> float | None:
    present = [float(value) for value in values if value is not None]
    return sum(present) / len(present) if present else None


def _bounded_or_none(value: float | None, *, lower: float = 0) -> float | None:
    if value is None or not math.isfinite(value):
        return None
    return _clamp(value, lower, 1)


def _clamp(value: float, lower: float, upper: float) -> float:
    return min(upper, max(lower, value))


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()
