from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
import pytest
from conftest import make_raw_sequence

from fingerspeak_ml.features import (
    ENGINEERED_FEATURE_LENGTH,
    FRAME_FEATURE_LENGTH,
    TimedFrame,
    add_velocity,
    build_model_input,
    compute_frame_features,
    flatten_landmarks,
    resample_sequence,
)


def test_feature_shapes_and_velocity_order(raw_sequence: np.ndarray) -> None:
    frame = compute_frame_features(raw_sequence[0])
    assert frame.shape == (FRAME_FEATURE_LENGTH,)
    features = build_model_input(raw_sequence, require_sequence_length=True)
    assert features.shape == (20, ENGINEERED_FEATURE_LENGTH)
    np.testing.assert_array_equal(features[0, FRAME_FEATURE_LENGTH:], np.zeros(15))

    fingertip_coordinate_indices = np.asarray([4, 8, 12, 16, 20]) * 3
    expected = np.concatenate(
        [
            features[1, index : index + 3] - features[0, index : index + 3]
            for index in fingertip_coordinate_indices
        ]
    )
    np.testing.assert_allclose(features[1, FRAME_FEATURE_LENGTH:], expected)


def test_features_are_rigid_transform_translation_and_scale_invariant(
    raw_sequence: np.ndarray,
) -> None:
    angle_x, angle_z = 0.61, -0.83
    rotation_x = np.asarray(
        [
            [1.0, 0.0, 0.0],
            [0.0, math.cos(angle_x), -math.sin(angle_x)],
            [0.0, math.sin(angle_x), math.cos(angle_x)],
        ]
    )
    rotation_z = np.asarray(
        [
            [math.cos(angle_z), -math.sin(angle_z), 0.0],
            [math.sin(angle_z), math.cos(angle_z), 0.0],
            [0.0, 0.0, 1.0],
        ]
    )
    rotation = rotation_z @ rotation_x
    points = raw_sequence.reshape(20, 21, 3)
    transformed = (points @ rotation.T) * 2.7 + np.asarray([5.0, -3.0, 1.4])
    expected = build_model_input(raw_sequence)
    actual = build_model_input(transformed.reshape(20, 63))
    np.testing.assert_allclose(actual, expected, rtol=1e-10, atol=1e-10)


def test_features_distinguish_different_hand_motion() -> None:
    index_curl = build_model_input(make_raw_sequence(kind=1))
    pinky_motion = build_model_input(make_raw_sequence(kind=2))
    assert np.linalg.norm(index_curl - pinky_motion) > 0.5


def test_degenerate_frame_remains_finite() -> None:
    result = compute_frame_features(np.zeros(63))
    assert result.shape == (83,)
    assert np.all(np.isfinite(result))


@dataclass
class Landmark:
    x: float
    y: float
    z: float | None = None


def test_flatten_landmarks_accepts_mappings_and_objects() -> None:
    mappings = [{"x": index, "y": index + 0.5} for index in range(21)]
    flattened = flatten_landmarks(mappings)
    assert flattened.shape == (63,)
    assert flattened[2] == 0.0
    objects = [Landmark(index, index + 0.5, None) for index in range(21)]
    np.testing.assert_array_equal(flatten_landmarks(objects), flattened)


def test_resample_sequence_matches_linear_browser_interpolation() -> None:
    frames = [
        TimedFrame(0.0, [0.0, 0.0]),
        TimedFrame(450.0, [0.5, 1.0]),
        TimedFrame(900.0, [1.0, 2.0]),
    ]
    result = resample_sequence(frames, count=5, window_ms=900.0)
    assert result is not None
    np.testing.assert_allclose(
        result,
        [[0.0, 0.0], [0.25, 0.5], [0.5, 1.0], [0.75, 1.5], [1.0, 2.0]],
    )


def test_resample_sequence_clamps_before_earliest_retained_frame() -> None:
    # The 900 ms window starts at t=0, but the first retained frame is t=50.
    # The legacy HTML extrapolated backwards; the product web client and Python
    # now hold the earliest observation until interpolation becomes possible.
    result = resample_sequence(
        [TimedFrame(50.0, [5.0]), TimedFrame(900.0, [90.0])],
        count=3,
        window_ms=900.0,
    )
    assert result is not None
    np.testing.assert_allclose(result[:, 0], [5.0, 45.0, 90.0])


def test_resample_sequence_rejects_bad_or_insufficient_input() -> None:
    assert resample_sequence([TimedFrame(0.0, [1.0])]) is None
    with pytest.raises(ValueError, match="ordered"):
        resample_sequence([TimedFrame(2.0, [1.0]), TimedFrame(1.0, [2.0])])
    with pytest.raises(ValueError, match="same length"):
        resample_sequence([TimedFrame(1.0, [1.0]), TimedFrame(2.0, [1.0, 2.0])])


def test_add_velocity_validates_shape() -> None:
    with pytest.raises(ValueError, match="shape"):
        add_velocity(np.zeros((20, 82)))
