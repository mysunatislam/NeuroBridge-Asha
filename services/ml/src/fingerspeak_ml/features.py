"""Numerically faithful Python port of FingerSpeak's browser feature pipeline.

The browser captures 21 MediaPipe landmarks (x, y, z), yielding 63 raw values
per frame.  Each frame is expressed in a hand-local basis, then augmented with
joint angles and pairwise fingertip distances (83 values).  Fingertip velocity
across frames adds another 15 values, for a final shape of ``(frames, 98)``.

Keep changes here in lock-step with the TypeScript/browser implementation.  A
model is only portable between Python and the browser when feature ordering and
floating-point semantics remain identical.
"""

from __future__ import annotations

import math
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from itertools import pairwise
from typing import Any

import numpy as np
from numpy.typing import ArrayLike, NDArray

SEQUENCE_LENGTH = 20
LANDMARK_COUNT = 21
RAW_FEATURE_LENGTH = LANDMARK_COUNT * 3
FRAME_FEATURE_LENGTH = 83
ENGINEERED_FEATURE_LENGTH = 98
FEATURE_VERSION = "3d-angle-motion-v1"
CAPTURE_WINDOW_MS = 900.0
RESAMPLE_GRACE_MS = 50.0

FINGERTIP_INDICES = (4, 8, 12, 16, 20)
FINGER_CHAINS = (
    (1, 2, 3, 4),
    (5, 6, 7, 8),
    (9, 10, 11, 12),
    (13, 14, 15, 16),
    (17, 18, 19, 20),
)

FloatArray = NDArray[np.float64]


def _as_finite_array(value: ArrayLike, *, shape: tuple[int, ...], name: str) -> FloatArray:
    try:
        array = np.asarray(value, dtype=np.float64)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must contain only numeric values") from exc
    if array.shape != shape:
        raise ValueError(f"{name} must have shape {shape}, got {array.shape}")
    if not np.all(np.isfinite(array)):
        raise ValueError(f"{name} must contain only finite values")
    return array


def _normalize(vector: FloatArray) -> FloatArray:
    # Mirrors `Math.hypot(...) || 1e-6`: use epsilon only for an exact zero.
    length = float(np.linalg.norm(vector))
    divisor = length if length != 0.0 else 1e-6
    return vector / divisor


def flatten_landmarks(landmarks: Sequence[Any]) -> FloatArray:
    """Flatten 21 MediaPipe-like landmarks to x/y/z triplets.

    A landmark may be a mapping with ``x``, ``y`` and optional ``z`` keys, or
    an object exposing attributes with those names. Missing/falsey ``z`` is
    treated as zero, matching the original JavaScript's ``lm[i].z || 0``.
    """

    if len(landmarks) != LANDMARK_COUNT:
        raise ValueError(f"landmarks must contain {LANDMARK_COUNT} points")
    output = np.empty(RAW_FEATURE_LENGTH, dtype=np.float64)
    for index, landmark in enumerate(landmarks):
        if isinstance(landmark, Mapping):
            try:
                x = landmark["x"]
                y = landmark["y"]
            except KeyError as exc:
                raise ValueError(f"landmark {index} is missing {exc.args[0]!r}") from exc
            z = landmark.get("z", 0.0) or 0.0
        else:
            try:
                x = landmark.x
                y = landmark.y
            except AttributeError as exc:
                raise ValueError(f"landmark {index} must expose x and y") from exc
            z = getattr(landmark, "z", 0.0) or 0.0
        try:
            values = (float(x), float(y), float(z))
        except (TypeError, ValueError) as exc:
            raise ValueError(f"landmark {index} contains a non-numeric coordinate") from exc
        if not all(math.isfinite(item) for item in values):
            raise ValueError(f"landmark {index} contains a non-finite coordinate")
        output[index * 3 : index * 3 + 3] = values
    return output


def compute_frame_features(raw63: ArrayLike) -> FloatArray:
    """Convert one 63-value landmark frame into 83 geometric features."""

    raw = _as_finite_array(raw63, shape=(RAW_FEATURE_LENGTH,), name="raw frame")
    points = raw.reshape(LANDMARK_COUNT, 3)
    wrist = points[0]
    middle_mcp = points[9]
    index_mcp = points[5]
    pinky_mcp = points[17]

    scale_length = float(np.linalg.norm(middle_mcp - wrist))
    if scale_length == 0.0:
        scale_length = 1e-6

    # Per-frame, right-handed local hand basis. This is the exact ordering used
    # by the legacy JavaScript: eY first, then projected eX, then eX cross eY.
    e_y = _normalize(middle_mcp - wrist)
    horizontal = pinky_mcp - index_mcp
    horizontal = horizontal - float(np.dot(horizontal, e_y)) * e_y
    e_x = _normalize(horizontal)
    e_z = _normalize(np.cross(e_x, e_y))

    relative = (points - wrist) / scale_length
    coordinates = np.empty((LANDMARK_COUNT, 3), dtype=np.float64)
    coordinates[:, 0] = relative @ e_x
    coordinates[:, 1] = relative @ e_y
    coordinates[:, 2] = relative @ e_z

    angles: list[float] = []
    for chain in FINGER_CHAINS:
        for joint in range(len(chain) - 2):
            a, b, c = points[chain[joint]], points[chain[joint + 1]], points[chain[joint + 2]]
            vector_1 = _normalize(a - b)
            vector_2 = _normalize(c - b)
            cosine = max(-1.0, min(1.0, float(np.dot(vector_1, vector_2))))
            angles.append(math.acos(cosine) / math.pi)

    distances: list[float] = []
    for left in range(len(FINGERTIP_INDICES)):
        for right in range(left + 1, len(FINGERTIP_INDICES)):
            point_a = points[FINGERTIP_INDICES[left]]
            point_b = points[FINGERTIP_INDICES[right]]
            distances.append(float(np.linalg.norm(point_a - point_b)) / scale_length)

    result = np.concatenate(
        (coordinates.reshape(-1), np.asarray(angles), np.asarray(distances))
    ).astype(np.float64, copy=False)
    if result.shape != (FRAME_FEATURE_LENGTH,):  # Defensive guard against ordering changes.
        raise AssertionError(
            f"feature pipeline emitted {result.shape}, expected {(FRAME_FEATURE_LENGTH,)}"
        )
    return result


def add_velocity(frame_features: ArrayLike) -> FloatArray:
    """Append normalized fingertip deltas to each 83-feature frame."""

    array = np.asarray(frame_features, dtype=np.float64)
    if array.ndim != 2 or array.shape[1] != FRAME_FEATURE_LENGTH:
        raise ValueError(
            f"frame_features must have shape (frames, {FRAME_FEATURE_LENGTH}), got {array.shape}"
        )
    if array.shape[0] == 0:
        raise ValueError("frame_features must contain at least one frame")
    if not np.all(np.isfinite(array)):
        raise ValueError("frame_features must contain only finite values")

    tip_coordinate_indices = np.asarray(FINGERTIP_INDICES, dtype=np.int64) * 3
    selected = np.stack(
        [array[:, index : index + 3] for index in tip_coordinate_indices], axis=1
    )
    velocity = np.zeros_like(selected)
    velocity[1:] = selected[1:] - selected[:-1]
    result = np.concatenate((array, velocity.reshape(array.shape[0], -1)), axis=1)
    if result.shape[1] != ENGINEERED_FEATURE_LENGTH:
        raise AssertionError("velocity feature ordering changed unexpectedly")
    return result


def build_model_input(
    raw_sequence: ArrayLike,
    *,
    require_sequence_length: bool = True,
) -> FloatArray:
    """Convert a raw landmark sequence into model-ready 98-value frames."""

    raw = np.asarray(raw_sequence, dtype=np.float64)
    if raw.ndim != 2 or raw.shape[1] != RAW_FEATURE_LENGTH:
        raise ValueError(
            f"raw_sequence must have shape (frames, {RAW_FEATURE_LENGTH}), got {raw.shape}"
        )
    if raw.shape[0] == 0:
        raise ValueError("raw_sequence must contain at least one frame")
    if require_sequence_length and raw.shape[0] != SEQUENCE_LENGTH:
        raise ValueError(
            f"raw_sequence must contain {SEQUENCE_LENGTH} frames, got {raw.shape[0]}"
        )
    if not np.all(np.isfinite(raw)):
        raise ValueError("raw_sequence must contain only finite values")
    per_frame = np.stack([compute_frame_features(frame) for frame in raw])
    return add_velocity(per_frame)


@dataclass(frozen=True, slots=True)
class TimedFrame:
    """A timestamped vector used by :func:`resample_sequence`."""

    t: float
    feat: ArrayLike


def _coerce_timed_frame(
    value: TimedFrame | Mapping[str, Any] | tuple[float, ArrayLike],
) -> tuple[float, FloatArray]:
    if isinstance(value, TimedFrame):
        timestamp, features = value.t, value.feat
    elif isinstance(value, Mapping):
        try:
            timestamp, features = value["t"], value["feat"]
        except KeyError as exc:
            raise ValueError(f"timed frame is missing {exc.args[0]!r}") from exc
    elif isinstance(value, tuple) and len(value) == 2:
        timestamp, features = value
    else:
        raise ValueError("timed frame must be TimedFrame, a {t, feat} mapping, or a pair")
    try:
        timestamp_float = float(timestamp)
        feature_array = np.asarray(features, dtype=np.float64)
    except (TypeError, ValueError) as exc:
        raise ValueError("timed frame contains non-numeric data") from exc
    if not math.isfinite(timestamp_float):
        raise ValueError("timed frame timestamp must be finite")
    if feature_array.ndim != 1 or feature_array.size == 0:
        raise ValueError("timed frame features must be a non-empty one-dimensional vector")
    if not np.all(np.isfinite(feature_array)):
        raise ValueError("timed frame features must be finite")
    return timestamp_float, feature_array


def resample_sequence(
    timed_frames: Sequence[TimedFrame | Mapping[str, Any] | tuple[float, ArrayLike]],
    count: int = SEQUENCE_LENGTH,
    window_ms: float = CAPTURE_WINDOW_MS,
    *,
    grace_ms: float = RESAMPLE_GRACE_MS,
) -> FloatArray | None:
    """Linearly resample timestamped frames, matching the current web implementation.

    ``None`` means that tracking supplied fewer than two usable frames. Inputs
    must be chronological because that is the contract of the camera ring buffer.
    Interpolation is clamped to the retained frame interval. This intentionally
    fixes the legacy prototype's pre-window extrapolation when its earliest
    retained frame arrived after the requested window start.
    """

    if count < 2:
        raise ValueError("count must be at least 2")
    if window_ms <= 0 or not math.isfinite(window_ms):
        raise ValueError("window_ms must be a positive finite number")
    if grace_ms < 0 or not math.isfinite(grace_ms):
        raise ValueError("grace_ms must be a non-negative finite number")
    if len(timed_frames) < 2:
        return None

    coerced = [_coerce_timed_frame(frame) for frame in timed_frames]
    timestamps = [frame[0] for frame in coerced]
    if any(later < earlier for earlier, later in pairwise(timestamps)):
        raise ValueError("timed_frames must be ordered by non-decreasing timestamp")
    width = coerced[0][1].shape
    if any(frame[1].shape != width for frame in coerced[1:]):
        raise ValueError("all timed frame feature vectors must have the same length")

    latest = coerced[-1][0]
    start = latest - window_ms
    in_window = [frame for frame in coerced if frame[0] >= start - grace_ms]
    if len(in_window) < 2:
        return None

    output: list[FloatArray] = []
    for index in range(count):
        target = start + (index / (count - 1)) * window_ms
        low, high = in_window[0], in_window[-1]
        for candidate_low, candidate_high in pairwise(in_window):
            if candidate_low[0] <= target <= candidate_high[0]:
                low, high = candidate_low, candidate_high
                break
        span = high[0] - low[0]
        alpha = (target - low[0]) / span if span > 0 else 0.0
        alpha = max(0.0, min(1.0, alpha))
        output.append(low[1] + (high[1] - low[1]) * alpha)
    return np.stack(output)
