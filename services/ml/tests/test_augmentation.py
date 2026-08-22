from __future__ import annotations

import numpy as np
import pytest

from fingerspeak_ml.augmentation import (
    AffineParameters,
    apply_affine,
    augment_raw,
    jitter,
    time_warp,
)


def test_affine_matches_legacy_xy_rotation_and_uniform_scale(raw_sequence: np.ndarray) -> None:
    parameters = AffineParameters(cosine=0.0, sine=1.0, scale=2.0)
    transformed = apply_affine(raw_sequence, parameters).reshape(20, 21, 3)
    original = raw_sequence.reshape(20, 21, 3)
    np.testing.assert_allclose(transformed[:, :, 0], -2.0 * original[:, :, 1])
    np.testing.assert_allclose(transformed[:, :, 1], 2.0 * original[:, :, 0])
    np.testing.assert_allclose(transformed[:, :, 2], 2.0 * original[:, :, 2])


def test_time_warp_preserves_endpoints(raw_sequence: np.ndarray) -> None:
    warped = time_warp(raw_sequence, np.random.default_rng(7))
    np.testing.assert_array_equal(warped[0], raw_sequence[0])
    np.testing.assert_array_equal(warped[-1], raw_sequence[-1])


def test_augmentation_is_reproducible_with_seed(raw_sequence: np.ndarray) -> None:
    left = augment_raw(raw_sequence, np.random.default_rng(1234))
    right = augment_raw(raw_sequence, np.random.default_rng(1234))
    np.testing.assert_array_equal(left, right)
    assert left.shape == raw_sequence.shape
    assert not np.array_equal(left, raw_sequence)


def test_jitter_rejects_negative_sigma(raw_sequence: np.ndarray) -> None:
    with pytest.raises(ValueError, match="sigma"):
        jitter(raw_sequence, np.random.default_rng(1), sigma=-0.1)
