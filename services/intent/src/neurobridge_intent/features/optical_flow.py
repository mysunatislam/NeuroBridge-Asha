"""OpenCV optical-flow motion energy inside a region of interest.

The analyzer computes dense Farneback flow between consecutive downscaled grey
frames and reduces it to five bounded numbers: mean/std magnitude, direction
consistency, dominant temporal frequency of the magnitude series, and the share of
that series' energy above 3 Hz. Twitches and tremor have high-frequency, low
amplitude, inconsistent direction; a smile is slow, symmetric and stops.

OpenCV is imported lazily so the rest of the package (and the phone runtime, which
uses a landmark-flow proxy instead) never needs it.
"""

from __future__ import annotations

import math
from collections import deque
from dataclasses import dataclass
from typing import Any

import numpy as np
from numpy.typing import NDArray

from .trajectory import dominant_frequency

FloatArray = NDArray[np.float64]


@dataclass(frozen=True, slots=True)
class FlowMetrics:
    mag_mean: float
    mag_std: float
    dir_consistency: float
    dominant_hz: float
    hf_ratio: float


class FlowSeriesAnalyzer:
    """Temporal analysis over a rolling series of per-frame flow magnitudes."""

    def __init__(self, *, rate_hz: float, seconds: float = 2.0) -> None:
        self.rate_hz = rate_hz
        self._series: deque[float] = deque(maxlen=max(8, int(rate_hz * seconds)))

    def reset(self) -> None:
        self._series.clear()

    def push(self, magnitude: float) -> tuple[float, float]:
        """Append a magnitude and return (dominant_hz, hf_ratio)."""

        if math.isfinite(magnitude):
            self._series.append(magnitude)
        return self.frequency_features()

    def frequency_features(self, *, hf_cutoff_hz: float = 3.0) -> tuple[float, float]:
        if len(self._series) < 8:
            return 0.0, 0.0
        x = np.asarray(self._series, dtype=np.float64)
        dominant, _ = dominant_frequency(x, self.rate_hz)
        centred = x - x.mean()
        spectrum = np.abs(np.fft.rfft(centred)) ** 2
        freqs = np.fft.rfftfreq(len(centred), d=1.0 / self.rate_hz)
        total = float(spectrum[1:].sum())
        if total <= 1e-12:
            return dominant, 0.0
        high = float(spectrum[freqs >= hf_cutoff_hz].sum())
        return dominant, high / total


def flow_statistics(flow: FloatArray) -> tuple[float, float, float]:
    """Reduce a dense (H, W, 2) flow field to (mag_mean, mag_std, dir_consistency)."""

    fx, fy = flow[..., 0], flow[..., 1]
    magnitude = np.hypot(fx, fy)
    mag_mean = float(magnitude.mean())
    mag_std = float(magnitude.std())
    moving = magnitude > max(0.15, mag_mean)
    if moving.sum() < 4:
        return mag_mean, mag_std, 0.0
    angles = np.arctan2(fy[moving], fx[moving])
    consistency = float(np.hypot(np.mean(np.cos(angles)), np.mean(np.sin(angles))))
    return mag_mean, mag_std, consistency


class OpticalFlowAnalyzer:
    """Dense Farneback optical flow over a face/hand ROI.

    Frames are downscaled to ``roi_size`` before flow computation so cost is bounded
    on a Raspberry Pi or laptop. Only the previous grey ROI is retained.
    """

    def __init__(self, *, rate_hz: float, roi_size: int = 96, seconds: float = 2.0) -> None:
        self.roi_size = roi_size
        self._cv2: Any | None = None
        self._previous: Any | None = None
        self._series = FlowSeriesAnalyzer(rate_hz=rate_hz, seconds=seconds)

    def _cv(self) -> Any:
        if self._cv2 is None:
            try:
                import cv2  # type: ignore[import-not-found]
            except ModuleNotFoundError as exc:  # pragma: no cover - depends on env
                raise RuntimeError(
                    "Optical flow needs the optional 'vision' extra (opencv-python-headless)."
                ) from exc
            self._cv2 = cv2
        return self._cv2

    def reset(self) -> None:
        self._previous = None
        self._series.reset()

    def update(self, frame_bgr: Any, roi: tuple[int, int, int, int] | None) -> FlowMetrics:
        """Process one BGR frame; ``roi`` is (x, y, w, h) in pixels or None for full frame."""

        cv2 = self._cv()
        if roi is not None:
            x, y, w, h = roi
            x, y = max(0, x), max(0, y)
            crop = frame_bgr[y : y + max(1, h), x : x + max(1, w)]
        else:
            crop = frame_bgr
        if crop.size == 0:
            self._previous = None
            return FlowMetrics(0.0, 0.0, 0.0, 0.0, 0.0)
        grey = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
        grey = cv2.resize(grey, (self.roi_size, self.roi_size), interpolation=cv2.INTER_AREA)
        if self._previous is None or self._previous.shape != grey.shape:
            self._previous = grey
            dominant, hf = self._series.push(0.0)
            return FlowMetrics(0.0, 0.0, 0.0, dominant, hf)
        flow = cv2.calcOpticalFlowFarneback(self._previous, grey, None, 0.5, 3, 15, 3, 5, 1.2, 0)
        self._previous = grey
        mag_mean, mag_std, consistency = flow_statistics(np.asarray(flow, dtype=np.float64))
        dominant, hf = self._series.push(mag_mean)
        return FlowMetrics(mag_mean, mag_std, consistency, dominant, hf)


class LandmarkFlowProxy:
    """Motion-energy proxy computed from landmark displacement (no image access).

    Used on phones where dense optical flow is too expensive or where only ML Kit
    contour points are available. Produces the same five channels so the shared
    classifiers stay valid across platforms.
    """

    def __init__(self, *, rate_hz: float, seconds: float = 2.0) -> None:
        self._previous: FloatArray | None = None
        self._series = FlowSeriesAnalyzer(rate_hz=rate_hz, seconds=seconds)

    def reset(self) -> None:
        self._previous = None
        self._series.reset()

    def update(self, points: FloatArray, scale: float) -> FlowMetrics:
        pts = np.asarray(points, dtype=np.float64)[:, :2] / max(scale, 1e-6)
        if self._previous is None or self._previous.shape != pts.shape:
            self._previous = pts
            dominant, hf = self._series.push(0.0)
            return FlowMetrics(0.0, 0.0, 0.0, dominant, hf)
        delta = pts - self._previous
        self._previous = pts
        magnitude = np.linalg.norm(delta, axis=1)
        mag_mean = float(magnitude.mean())
        mag_std = float(magnitude.std())
        moving = magnitude > max(1e-4, mag_mean)
        if moving.sum() >= 4:
            angles = np.arctan2(delta[moving, 1], delta[moving, 0])
            consistency = float(np.hypot(np.mean(np.cos(angles)), np.mean(np.sin(angles))))
        else:
            consistency = 0.0
        dominant, hf = self._series.push(mag_mean)
        return FlowMetrics(mag_mean, mag_std, consistency, dominant, hf)
