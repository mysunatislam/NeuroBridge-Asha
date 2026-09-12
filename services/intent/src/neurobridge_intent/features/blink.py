"""Blink event detection from an eye-aspect-ratio (EAR) time series.

A blink is a *closure* (EAR below a patient-relative threshold) that lasts between
``min_duration_ms`` and ``max_duration_ms``. Longer closures are reported as held
closures so the temporal layer can distinguish a deliberate long blink from a
spontaneous one. The detector never decides whether a blink is a command.
"""

from __future__ import annotations

import math
from collections.abc import Sequence
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class BlinkEvent:
    start_s: float
    end_s: float
    depth: float  # 0 (open) .. 1 (fully closed) relative to the open baseline
    closing_velocity: float  # EAR units per second, positive = closing

    @property
    def duration_ms(self) -> float:
        return (self.end_s - self.start_s) * 1000.0


class BlinkDetector:
    """Stateful closure detector fed one EAR sample at a time."""

    def __init__(
        self,
        *,
        open_ear: float = 0.30,
        closure_ratio: float = 0.55,
        min_duration_ms: float = 60.0,
        max_duration_ms: float = 700.0,
    ) -> None:
        if not 0 < closure_ratio < 1:
            raise ValueError("closure_ratio must be between 0 and 1")
        self.open_ear = max(open_ear, 1e-3)
        self.closure_ratio = closure_ratio
        self.min_duration_ms = min_duration_ms
        self.max_duration_ms = max_duration_ms
        self._closed_since: float | None = None
        self._min_ear = math.inf
        self._last: tuple[float, float] | None = None
        self._max_velocity = 0.0

    @property
    def threshold(self) -> float:
        return self.open_ear * (1.0 - self.closure_ratio)

    def set_open_baseline(self, open_ear: float) -> None:
        if math.isfinite(open_ear) and open_ear > 0:
            self.open_ear = open_ear

    def reset(self) -> None:
        self._closed_since = None
        self._min_ear = math.inf
        self._last = None
        self._max_velocity = 0.0

    def update(self, t_s: float, ear: float) -> BlinkEvent | None:
        """Feed a sample; returns a completed blink when the eyes re-open."""

        if not (math.isfinite(t_s) and math.isfinite(ear)):
            self.reset()
            return None
        velocity = 0.0
        if self._last is not None:
            dt = t_s - self._last[0]
            if dt > 0:
                velocity = (self._last[1] - ear) / dt
        self._last = (t_s, ear)

        closed = ear < self.threshold
        if closed:
            if self._closed_since is None:
                self._closed_since = t_s
                self._min_ear = ear
                self._max_velocity = max(velocity, 0.0)
            else:
                self._min_ear = min(self._min_ear, ear)
                self._max_velocity = max(self._max_velocity, velocity)
            return None

        if self._closed_since is None:
            return None
        start = self._closed_since
        self._closed_since = None
        duration_ms = (t_s - start) * 1000.0
        depth = max(0.0, min(1.0, 1.0 - self._min_ear / self.open_ear))
        self._min_ear = math.inf
        if duration_ms < self.min_duration_ms:
            return None
        return BlinkEvent(start, t_s, depth, self._max_velocity)

    @property
    def is_closed(self) -> bool:
        return self._closed_since is not None

    def closed_duration_ms(self, now_s: float) -> float:
        if self._closed_since is None:
            return 0.0
        return (now_s - self._closed_since) * 1000.0


def blink_statistics(events: Sequence[BlinkEvent], span_s: float) -> dict[str, float]:
    """Summarise blink timing over ``span_s`` seconds.

    Returns rate (Hz), mean/SD duration, duration coefficient of variation and the
    inter-blink-interval coefficient of variation. Spontaneous blinking has a large
    interval CV (roughly Poisson); a deliberate triple blink has a small one.
    """

    span = max(span_s, 1e-6)
    count = len(events)
    if count == 0:
        return {
            "count": 0.0,
            "rate_hz": 0.0,
            "mean_duration_ms": 0.0,
            "sd_duration_ms": 0.0,
            "duration_cv": 0.0,
            "mean_interval_s": 0.0,
            "interval_cv": 0.0,
            "mean_depth": 0.0,
            "mean_velocity": 0.0,
        }
    durations = [event.duration_ms for event in events]
    mean_duration = sum(durations) / count
    sd_duration = math.sqrt(sum((d - mean_duration) ** 2 for d in durations) / count)
    intervals = [b.start_s - a.end_s for a, b in zip(events, events[1:], strict=False)]
    if intervals:
        mean_interval = sum(intervals) / len(intervals)
        sd_interval = math.sqrt(sum((i - mean_interval) ** 2 for i in intervals) / len(intervals))
        interval_cv = sd_interval / mean_interval if mean_interval > 0 else 0.0
    else:
        mean_interval = 0.0
        interval_cv = 0.0
    return {
        "count": float(count),
        "rate_hz": count / span,
        "mean_duration_ms": mean_duration,
        "sd_duration_ms": sd_duration,
        "duration_cv": sd_duration / mean_duration if mean_duration > 0 else 0.0,
        "mean_interval_s": mean_interval,
        "interval_cv": interval_cv,
        "mean_depth": sum(event.depth for event in events) / count,
        "mean_velocity": sum(event.closing_velocity for event in events) / count,
    }
