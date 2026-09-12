"""Movement trajectory analysis: acceleration, jerk, smoothness and phase structure.

An intentional movement follows *start -> movement -> hold -> release*. Involuntary
movement shows random acceleration, no controlled endpoint and irregular patterns.
These functions quantify that on any (t, x, y) trajectory, such as the face centre,
a wrist, or a lip landmark.
"""

from __future__ import annotations

import math
from collections import deque
from dataclasses import dataclass

import numpy as np
from numpy.typing import ArrayLike, NDArray

FloatArray = NDArray[np.float64]


@dataclass(frozen=True, slots=True)
class TrajectoryMetrics:
    velocity_rms: float
    accel_rms: float
    jerk_rms: float
    smoothness: float  # log dimensionless jerk; closer to 0 is smoother
    direction_consistency: float  # 0..1, mean resultant length of heading
    hold_fraction: float  # fraction of frames nearly stationary after a movement
    onset_count: int
    peak_amplitude: float
    dominant_hz: float
    rhythmicity: float  # 0..1 autocorrelation peak strength
    sustained_seconds: float  # longest run of continuous movement


def _derivative(values: FloatArray, dt: float) -> FloatArray:
    if len(values) < 2:
        return np.zeros_like(values)
    return np.gradient(values, dt, axis=0)


def dominant_frequency(
    signal: ArrayLike, rate_hz: float, *, min_hz: float = 0.5
) -> tuple[float, float]:
    """Return (dominant frequency, rhythmicity) of a 1-D signal.

    Rhythmicity is the height of the first autocorrelation peak after lag 0 (0..1).
    Tremor and clonic activity produce a strong, narrow peak; voluntary movement does
    not.
    """

    x = np.asarray(signal, dtype=np.float64)
    n = len(x)
    if n < 8 or not np.isfinite(x).all():
        return 0.0, 0.0
    x = x - x.mean()
    if np.allclose(x, 0.0):
        return 0.0, 0.0
    spectrum = np.abs(np.fft.rfft(x * np.hanning(n)))
    freqs = np.fft.rfftfreq(n, d=1.0 / rate_hz)
    mask = freqs >= min_hz
    if not mask.any():
        return 0.0, 0.0
    dominant = float(freqs[mask][int(np.argmax(spectrum[mask]))])
    auto = np.correlate(x, x, mode="full")[n - 1 :]
    auto = auto / (auto[0] if auto[0] > 0 else 1.0)
    # First local maximum after the initial decay.
    rhythm = 0.0
    for lag in range(2, n - 1):
        if auto[lag] > auto[lag - 1] and auto[lag] >= auto[lag + 1]:
            rhythm = max(0.0, float(auto[lag]))
            break
    return dominant, rhythm


def principal_projection(points: ArrayLike) -> FloatArray:
    """Project a centred (N, 2) trajectory onto its principal axis.

    Oscillation analysis must not depend on which axis the movement happens to
    lie on; a 2x2 covariance eigenvector keeps the maths identical in Dart.
    """

    p = np.asarray(points, dtype=np.float64)
    centred = p - p.mean(axis=0)
    a = float(np.sum(centred[:, 0] ** 2))
    b = float(np.sum(centred[:, 0] * centred[:, 1]))
    d = float(np.sum(centred[:, 1] ** 2))
    theta = 0.5 * math.atan2(2.0 * b, a - d)
    direction = np.array([math.cos(theta), math.sin(theta)])
    return centred @ direction


def segment_phases(
    speed: ArrayLike, dt: float, *, move_threshold: float, hold_threshold: float | None = None
) -> tuple[int, float, float]:
    """Return (onset_count, hold_fraction, sustained_seconds) from a speed series.

    ``hold_fraction`` is the share of frames after the first onset where speed sits
    below ``hold_threshold``: a controlled movement stops at an endpoint, a spasm or
    tremor does not.
    """

    s = np.asarray(speed, dtype=np.float64)
    if s.size == 0:
        return 0, 0.0, 0.0
    hold_threshold = move_threshold * 0.5 if hold_threshold is None else hold_threshold
    moving = s > move_threshold
    onsets = int(np.sum(moving[1:] & ~moving[:-1]) + (1 if moving[0] else 0))
    first = int(np.argmax(moving)) if moving.any() else -1
    if first < 0:
        return 0, 0.0, 0.0
    after = s[first:]
    hold_fraction = float(np.mean(after < hold_threshold)) if after.size else 0.0
    longest = current = 0
    for flag in moving:
        current = current + 1 if flag else 0
        longest = max(longest, current)
    return onsets, hold_fraction, longest * dt


def analyze_trajectory(points: ArrayLike, dt: float, *, rate_hz: float) -> TrajectoryMetrics:
    """Compute :class:`TrajectoryMetrics` for an ``(N, 2)`` trajectory sampled at ``dt``."""

    p = np.asarray(points, dtype=np.float64)
    if p.ndim != 2 or p.shape[1] != 2 or p.shape[0] < 3:
        return TrajectoryMetrics(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    v = _derivative(p, dt)
    a = _derivative(v, dt)
    j = _derivative(a, dt)
    speed = np.linalg.norm(v, axis=1)
    velocity_rms = float(np.sqrt(np.mean(speed**2)))
    accel_rms = float(np.sqrt(np.mean(np.sum(a**2, axis=1))))
    jerk_rms = float(np.sqrt(np.mean(np.sum(j**2, axis=1))))
    duration = dt * (len(p) - 1)
    peak_speed = float(np.max(speed)) if speed.size else 0.0
    if peak_speed > 1e-9 and duration > 0:
        # Log dimensionless jerk (Balasubramanian et al.); more negative = less smooth.
        ldj = -math.log((duration**3 / peak_speed**2) * float(np.sum(np.sum(j**2, axis=1)) * dt))
        smoothness = float(np.clip(ldj, -30.0, 0.0))
    else:
        smoothness = 0.0
    headings = np.arctan2(v[:, 1], v[:, 0])[speed > 1e-6]
    if headings.size:
        direction_consistency = float(
            np.hypot(np.mean(np.cos(headings)), np.mean(np.sin(headings)))
        )
    else:
        direction_consistency = 0.0
    move_threshold = max(0.25 * peak_speed, 1e-6)
    onsets, hold_fraction, sustained = segment_phases(speed, dt, move_threshold=move_threshold)
    displacement = np.linalg.norm(p - p[0], axis=1)
    peak_amplitude = float(np.max(displacement))
    dominant_hz, rhythmicity = dominant_frequency(principal_projection(p), rate_hz)
    return TrajectoryMetrics(
        velocity_rms=velocity_rms,
        accel_rms=accel_rms,
        jerk_rms=jerk_rms,
        smoothness=smoothness,
        direction_consistency=direction_consistency,
        hold_fraction=hold_fraction,
        onset_count=onsets,
        peak_amplitude=peak_amplitude,
        dominant_hz=dominant_hz,
        rhythmicity=rhythmicity,
        sustained_seconds=sustained,
    )


class TrajectoryAnalyzer:
    """Rolling (x, y) buffer that yields :class:`TrajectoryMetrics` on demand."""

    def __init__(self, *, rate_hz: float, seconds: float) -> None:
        self.rate_hz = rate_hz
        self.dt = 1.0 / rate_hz
        self._points: deque[tuple[float, float]] = deque(maxlen=max(3, int(rate_hz * seconds)))

    def reset(self) -> None:
        self._points.clear()

    def push(self, x: float, y: float) -> None:
        if math.isfinite(x) and math.isfinite(y):
            self._points.append((x, y))

    def __len__(self) -> int:
        return len(self._points)

    def metrics(self) -> TrajectoryMetrics:
        return analyze_trajectory(np.asarray(self._points), self.dt, rate_hz=self.rate_hz)
