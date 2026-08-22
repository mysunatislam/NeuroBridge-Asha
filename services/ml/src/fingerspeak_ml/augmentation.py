"""Raw-landmark augmentation matching the browser prototype."""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
from numpy.typing import ArrayLike, NDArray

from .features import RAW_FEATURE_LENGTH

FloatArray = NDArray[np.float64]


@dataclass(frozen=True, slots=True)
class AffineParameters:
    cosine: float
    sine: float
    scale: float


def _raw_sequence(value: ArrayLike) -> FloatArray:
    array = np.asarray(value, dtype=np.float64)
    if array.ndim != 2 or array.shape[1] != RAW_FEATURE_LENGTH or array.shape[0] == 0:
        raise ValueError(f"raw sequence must have shape (frames, {RAW_FEATURE_LENGTH})")
    if not np.all(np.isfinite(array)):
        raise ValueError("raw sequence must contain only finite values")
    return array


def random_affine(rng: np.random.Generator) -> AffineParameters:
    theta = (float(rng.random()) - 0.5) * 0.35
    scale = 0.9 + float(rng.random()) * 0.2
    return AffineParameters(math.cos(theta), math.sin(theta), scale)


def apply_affine(sequence: ArrayLike, parameters: AffineParameters) -> FloatArray:
    raw = _raw_sequence(sequence)
    points = raw.reshape(raw.shape[0], 21, 3)
    output = points.copy()
    x = points[:, :, 0]
    y = points[:, :, 1]
    output[:, :, 0] = (x * parameters.cosine - y * parameters.sine) * parameters.scale
    output[:, :, 1] = (x * parameters.sine + y * parameters.cosine) * parameters.scale
    output[:, :, 2] = points[:, :, 2] * parameters.scale
    return output.reshape(raw.shape)


def time_warp(sequence: ArrayLike, rng: np.random.Generator) -> FloatArray:
    raw = _raw_sequence(sequence)
    frame_count = raw.shape[0]
    if frame_count == 1:
        return raw.copy()
    strength = (float(rng.random()) - 0.5) * 0.6
    output = np.empty_like(raw)
    for index in range(frame_count):
        unit = index / (frame_count - 1)
        warped = unit + strength * math.sin(math.pi * unit) * 0.3
        warped = min(1.0, max(0.0, warped))
        position = warped * (frame_count - 1)
        low = math.floor(position)
        high = min(frame_count - 1, low + 1)
        alpha = position - low
        output[index] = raw[low] + (raw[high] - raw[low]) * alpha
    return output


def jitter(sequence: ArrayLike, rng: np.random.Generator, sigma: float = 0.01) -> FloatArray:
    raw = _raw_sequence(sequence)
    if sigma < 0 or not math.isfinite(sigma):
        raise ValueError("sigma must be a non-negative finite number")
    return raw + (rng.random(raw.shape) * 2.0 - 1.0) * sigma


def augment_raw(sequence: ArrayLike, rng: np.random.Generator | None = None) -> FloatArray:
    """Apply affine, timing, and tracking-noise augmentation in legacy order."""

    generator = rng if rng is not None else np.random.default_rng()
    transformed = apply_affine(sequence, random_affine(generator))
    transformed = time_warp(transformed, generator)
    return jitter(transformed, generator)
