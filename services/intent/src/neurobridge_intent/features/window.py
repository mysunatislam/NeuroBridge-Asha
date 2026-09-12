"""Per-frame feature vectors and sliding-window aggregation.

``FrameFeatures`` is the 28-channel vector from :mod:`neurobridge_intent.schema`.
``window_features`` turns the last ``WINDOW_FRAMES`` frames into the fixed-length
vector consumed by the intent and abnormal-movement classifiers. The Dart runtime
implements the same arithmetic; ``tests/test_window.py`` pins reference values.
"""

from __future__ import annotations

import math
from collections import deque
from collections.abc import Iterable, Sequence
from dataclasses import dataclass

import numpy as np
from numpy.typing import ArrayLike, NDArray

from ..schema import (
    EVENT_FEATURES,
    FRAME_FEATURE_COUNT,
    FRAME_INDEX,
    FRAME_RATE_HZ,
    WINDOW_FEATURE_COUNT,
    WINDOW_FRAMES,
)
from .blink import BlinkDetector, BlinkEvent, blink_statistics
from .trajectory import analyze_trajectory

FloatArray = NDArray[np.float64]


@dataclass(frozen=True, slots=True)
class FrameFeatures:
    """One resampled frame: timestamp plus the schema-ordered channel vector."""

    t_s: float
    values: FloatArray

    def __post_init__(self) -> None:
        values = np.asarray(self.values, dtype=np.float64)
        if values.shape != (FRAME_FEATURE_COUNT,):
            raise ValueError(f"values must have shape ({FRAME_FEATURE_COUNT},), got {values.shape}")
        if not np.all(np.isfinite(values)):
            raise ValueError("frame features must be finite")
        object.__setattr__(self, "values", values)

    @classmethod
    def from_mapping(cls, t_s: float, mapping: dict[str, float]) -> FrameFeatures:
        values = np.zeros(FRAME_FEATURE_COUNT, dtype=np.float64)
        for name, value in mapping.items():
            index = FRAME_INDEX.get(name)
            if index is None:
                raise KeyError(f"unknown frame feature {name!r}")
            values[index] = float(value)
        if "ear_mean" not in mapping and ("ear_left" in mapping or "ear_right" in mapping):
            values[FRAME_INDEX["ear_mean"]] = (
                values[FRAME_INDEX["ear_left"]] + values[FRAME_INDEX["ear_right"]]
            ) / 2.0
        return cls(t_s, values)

    def __getitem__(self, name: str) -> float:
        return float(self.values[FRAME_INDEX[name]])


def _channel_stats(matrix: FloatArray) -> FloatArray:
    """Per-channel mean/std/min/max/range/mean_abs_diff, flattened channel-major."""

    mean = matrix.mean(axis=0)
    std = matrix.std(axis=0)
    minimum = matrix.min(axis=0)
    maximum = matrix.max(axis=0)
    rng = maximum - minimum
    if matrix.shape[0] > 1:
        mad = np.abs(np.diff(matrix, axis=0)).mean(axis=0)
    else:
        mad = np.zeros_like(mean)
    return np.stack([mean, std, minimum, maximum, rng, mad], axis=1).reshape(-1)


def detect_blinks(
    timestamps: Sequence[float], ear: Sequence[float], *, open_ear: float | None = None
) -> list[BlinkEvent]:
    """Run the blink detector over a finished series (used for window features)."""

    ear_array = np.asarray(ear, dtype=np.float64)
    if ear_array.size == 0:
        return []
    baseline = open_ear if open_ear else float(np.percentile(ear_array, 80))
    detector = BlinkDetector(open_ear=max(baseline, 1e-3))
    events: list[BlinkEvent] = []
    for t, value in zip(timestamps, ear_array, strict=False):
        event = detector.update(float(t), float(value))
        if event is not None:
            events.append(event)
    return events


def window_features(
    frames: Sequence[FrameFeatures] | ArrayLike,
    *,
    timestamps: Sequence[float] | None = None,
    rate_hz: float = FRAME_RATE_HZ,
    open_ear: float | None = None,
) -> FloatArray:
    """Aggregate a window of frames into the classifier feature vector."""

    if len(frames) == 0:
        raise ValueError("window must contain at least one frame")
    if isinstance(frames[0], FrameFeatures):
        matrix = np.stack([frame.values for frame in frames])
        times = np.asarray([frame.t_s for frame in frames], dtype=np.float64)
    else:
        matrix = np.asarray(frames, dtype=np.float64)
        if matrix.ndim != 2 or matrix.shape[1] != FRAME_FEATURE_COUNT:
            raise ValueError("frames must be (n, FRAME_FEATURE_COUNT)")
        if timestamps is None:
            times = np.arange(matrix.shape[0], dtype=np.float64) / rate_hz
        else:
            times = np.asarray(timestamps, dtype=np.float64)
    if not np.all(np.isfinite(matrix)):
        raise ValueError("frames must be finite")

    stats = _channel_stats(matrix)
    span = float(times[-1] - times[0]) if len(times) > 1 else 1.0 / rate_hz
    span = max(span, 1.0 / rate_hz)
    dt = 1.0 / rate_hz

    ear = matrix[:, FRAME_INDEX["ear_mean"]]
    blinks = detect_blinks(times, ear, open_ear=open_ear)
    blink_stats = blink_statistics(blinks, span)

    head = np.stack(
        [matrix[:, FRAME_INDEX["head_yaw"]], matrix[:, FRAME_INDEX["head_pitch"]]], axis=1
    )
    head_metrics = analyze_trajectory(head, dt, rate_hz=rate_hz)
    face = np.stack([matrix[:, FRAME_INDEX["face_cx"]], matrix[:, FRAME_INDEX["face_cy"]]], axis=1)
    face_metrics = analyze_trajectory(face, dt, rate_hz=rate_hz)

    # Activity envelope used for onset/hold analysis: normalised motion channels.
    activity = np.abs(matrix[:, FRAME_INDEX["head_angular_speed"]]) / 60.0
    activity = activity + matrix[:, FRAME_INDEX["hand_speed"]] * 2.0
    activity = activity + matrix[:, FRAME_INDEX["flow_mag_mean"]] * 4.0
    activity = activity + np.abs(np.gradient(matrix[:, FRAME_INDEX["mouth_open_ratio"]], dt)) * 0.5
    activity = activity + np.abs(np.gradient(matrix[:, FRAME_INDEX["brow_raise"]], dt)) * 0.5
    peak = float(activity.max()) if activity.size else 0.0
    move_threshold = max(0.25 * peak, 1e-6)
    from .trajectory import segment_phases

    onsets, hold_fraction, sustained = segment_phases(activity, dt, move_threshold=move_threshold)

    events = np.asarray(
        [
            blink_stats["count"],
            blink_stats["mean_duration_ms"],
            blink_stats["duration_cv"],
            blink_stats["interval_cv"],
            blink_stats["rate_hz"],
            head_metrics.dominant_hz,
            head_metrics.rhythmicity,
            face_metrics.jerk_rms,
            face_metrics.smoothness,
            hold_fraction,
            max(head_metrics.direction_consistency, face_metrics.direction_consistency),
            float(onsets),
            peak,
            sustained,
        ],
        dtype=np.float64,
    )
    assert events.shape[0] == len(EVENT_FEATURES)
    result = np.concatenate([stats, events])
    if result.shape[0] != WINDOW_FEATURE_COUNT:  # pragma: no cover - schema guard
        raise AssertionError("window feature count drifted from schema")
    return result


class FeatureWindow:
    """Ring buffer of frames with helpers for the classifiers and the temporal model."""

    def __init__(
        self,
        *,
        window_frames: int = WINDOW_FRAMES,
        sequence_frames: int | None = None,
        rate_hz: float = FRAME_RATE_HZ,
    ) -> None:
        capacity = max(window_frames, sequence_frames or 0)
        self.window_frames = window_frames
        self.sequence_frames = sequence_frames or window_frames
        self.rate_hz = rate_hz
        self._frames: deque[FrameFeatures] = deque(maxlen=capacity)

    def __len__(self) -> int:
        return len(self._frames)

    def clear(self) -> None:
        self._frames.clear()

    def push(self, frame: FrameFeatures) -> None:
        if self._frames and frame.t_s < self._frames[-1].t_s:
            # Time went backwards (camera restart); start over.
            self._frames.clear()
        self._frames.append(frame)

    def extend(self, frames: Iterable[FrameFeatures]) -> None:
        for frame in frames:
            self.push(frame)

    @property
    def is_ready(self) -> bool:
        return len(self._frames) >= min(self.window_frames, self.sequence_frames)

    def latest(self) -> FrameFeatures | None:
        return self._frames[-1] if self._frames else None

    def window(self) -> list[FrameFeatures]:
        return list(self._frames)[-self.window_frames :]

    def features(self, *, open_ear: float | None = None) -> FloatArray:
        frames = self.window()
        if not frames:
            raise ValueError("window is empty")
        return window_features(frames, rate_hz=self.rate_hz, open_ear=open_ear)

    def sequence(self) -> FloatArray:
        """Last ``sequence_frames`` frames as a (T, C) matrix, front-padded if short."""

        frames = list(self._frames)[-self.sequence_frames :]
        if not frames:
            return np.zeros((self.sequence_frames, FRAME_FEATURE_COUNT))
        matrix = np.stack([frame.values for frame in frames])
        if matrix.shape[0] < self.sequence_frames:
            pad = np.repeat(matrix[:1], self.sequence_frames - matrix.shape[0], axis=0)
            matrix = np.concatenate([pad, matrix], axis=0)
        return matrix

    def seconds_covered(self) -> float:
        if len(self._frames) < 2:
            return 0.0
        return self._frames[-1].t_s - self._frames[0].t_s


def resample_to_grid(
    frames: Sequence[FrameFeatures], *, rate_hz: float = FRAME_RATE_HZ
) -> list[FrameFeatures]:
    """Linearly resample irregular camera frames onto the nominal analysis grid."""

    if len(frames) < 2:
        return list(frames)
    times = np.asarray([frame.t_s for frame in frames])
    matrix = np.stack([frame.values for frame in frames])
    grid = np.arange(times[0], times[-1] + 1e-9, 1.0 / rate_hz)
    out: list[FrameFeatures] = []
    for t in grid:
        values = np.array([np.interp(t, times, matrix[:, c]) for c in range(matrix.shape[1])])
        out.append(FrameFeatures(float(t), values))
    return out


def is_finite_number(value: float) -> bool:
    return isinstance(value, (int, float)) and math.isfinite(value)
