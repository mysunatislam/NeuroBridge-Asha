from __future__ import annotations

import math

import numpy as np
import pytest

from neurobridge_intent.features.blink import BlinkDetector, blink_statistics
from neurobridge_intent.features.face import FaceFeatureExtractor, eye_aspect_ratio
from neurobridge_intent.features.gesture import GestureFeatureExtractor, joint_angle
from neurobridge_intent.features.optical_flow import (
    FlowSeriesAnalyzer,
    LandmarkFlowProxy,
    flow_statistics,
)
from neurobridge_intent.features.trajectory import (
    analyze_trajectory,
    dominant_frequency,
    segment_phases,
)
from neurobridge_intent.features.window import FeatureWindow, FrameFeatures, window_features
from neurobridge_intent.schema import (
    FRAME_FEATURE_COUNT,
    FRAME_INDEX,
    WINDOW_FEATURE_COUNT,
    WINDOW_FEATURES,
)


def test_eye_aspect_ratio_open_vs_closed():
    open_eye = [(0, 0), (1, -0.4), (2, -0.4), (3, 0), (2, 0.4), (1, 0.4)]
    closed_eye = [(0, 0), (1, -0.02), (2, -0.02), (3, 0), (2, 0.02), (1, 0.02)]
    assert eye_aspect_ratio(open_eye) > 0.2
    assert eye_aspect_ratio(closed_eye) < 0.05
    with pytest.raises(ValueError):
        eye_aspect_ratio([(0, 0)] * 5)


def test_blink_detector_reports_duration_depth_and_ignores_micro_dips():
    detector = BlinkDetector(open_ear=0.30)
    t = 0.0
    events = []
    ear = [0.30] * 10 + [0.05] * 4 + [0.30] * 10  # 200 ms blink at 20 Hz
    for value in ear:
        event = detector.update(t, value)
        if event:
            events.append(event)
        t += 0.05
    assert len(events) == 1
    assert 150 <= events[0].duration_ms <= 250
    assert events[0].depth > 0.7
    assert events[0].closing_velocity > 0
    # A single-sample dip (50 ms) is below the minimum duration.
    detector.reset()
    t = 0.0
    events = []
    for value in [0.30] * 5 + [0.05] + [0.30] * 5:
        event = detector.update(t, value)
        if event:
            events.append(event)
        t += 0.05
    assert events == []


def test_blink_statistics_regular_vs_random():
    detector = BlinkDetector(open_ear=0.30)

    def run(times):
        detector.reset()
        events = []
        t = 0.0
        while t < 10.0:
            closed = any(abs(t - s) < 0.1 for s in times)
            event = detector.update(t, 0.05 if closed else 0.30)
            if event:
                events.append(event)
            t += 0.05
        return blink_statistics(events, 10.0)

    regular = run([1.0, 1.4, 1.8])
    random = run([0.5, 3.1, 3.4, 7.9])
    assert regular["count"] == 3
    assert regular["interval_cv"] < 0.2
    assert random["interval_cv"] > regular["interval_cv"]


def _synthetic_face(scale: float = 0.2, yaw_shift: float = 0.0, mouth_open: float = 0.0):
    lm = np.zeros((478, 3))
    lm[33] = (0.4, 0.4, 0)
    lm[263] = (0.4 + scale, 0.4, 0)
    lm[133] = (0.45, 0.4, 0)
    lm[362] = (0.55, 0.4, 0)
    for idx, y in ((160, 0.385), (158, 0.385), (153, 0.415), (144, 0.415)):
        lm[idx] = (0.43, y, 0)
    for idx, y in ((385, 0.385), (387, 0.385), (373, 0.415), (380, 0.415)):
        lm[idx] = (0.57, y, 0)
    lm[1] = (0.5 + yaw_shift, 0.5, 0)
    lm[10] = (0.5, 0.25, 0)
    lm[152] = (0.5, 0.72, 0)
    lm[61] = (0.45, 0.6, 0)
    lm[291] = (0.55, 0.6, 0)
    lm[13] = (0.5, 0.59, 0)
    lm[14] = (0.5, 0.61 + mouth_open, 0)
    lm[0] = (0.5, 0.58, 0)
    lm[17] = (0.5, 0.63, 0)
    lm[105] = (0.43, 0.34, 0)
    lm[334] = (0.57, 0.34, 0)
    lm[159] = (0.43, 0.385, 0)
    lm[386] = (0.57, 0.385, 0)
    return lm


def test_face_feature_extractor_tracks_mouth_and_yaw():
    extractor = FaceFeatureExtractor()
    neutral = extractor.extract(_synthetic_face(), 0.0)
    turned = extractor.extract(_synthetic_face(yaw_shift=0.03), 0.05)
    opened = extractor.extract(_synthetic_face(mouth_open=0.05), 0.10)
    assert neutral.ear_mean > 0.05
    assert abs(neutral.head_yaw) < 1.0
    assert turned.head_yaw > 5.0
    assert turned.head_angular_speed > 0
    assert opened.mouth_open_ratio > neutral.mouth_open_ratio + 0.1
    with pytest.raises(ValueError):
        extractor.extract(np.zeros((10, 3)), 0.0)


def test_gesture_extractor_speed_and_elbow_angle():
    assert math.isclose(joint_angle((0, 0), (1, 0), (2, 0)), 180.0)
    assert math.isclose(joint_angle((0, 0), (1, 0), (1, 1)), 90.0)
    extractor = GestureFeatureExtractor()
    hand = np.zeros((21, 3))
    hand[0] = (0.5, 0.8, 0)
    first = extractor.extract(0.0, hand_landmarks=hand)
    hand[0] = (0.5, 0.7, 0)
    second = extractor.extract(0.05, hand_landmarks=hand)
    assert first.hand_present == 1.0 and first.hand_speed == 0.0
    assert second.hand_speed == pytest.approx(2.0, rel=1e-6)
    assert second.hand_direction < 0  # moving up the frame
    missing = extractor.extract(0.10)
    assert missing.hand_present == 0.0


def test_trajectory_metrics_distinguish_hold_from_tremor():
    dt = 0.05
    t = np.arange(0, 3, dt)
    # Controlled: move then hold.
    controlled = np.zeros((len(t), 2))
    ramp = np.clip((t - 0.5) / 0.4, 0, 1)
    controlled[:, 0] = 0.1 * ramp
    tremor = np.zeros((len(t), 2))
    tremor[:, 0] = 0.01 * np.sin(2 * np.pi * 8 * t)
    m_controlled = analyze_trajectory(controlled, dt, rate_hz=20)
    m_tremor = analyze_trajectory(tremor, dt, rate_hz=20)
    assert m_controlled.hold_fraction > 0.5
    assert m_controlled.onset_count == 1
    assert m_tremor.rhythmicity > m_controlled.rhythmicity
    assert 6.0 <= m_tremor.dominant_hz <= 10.0
    assert m_tremor.hold_fraction < m_controlled.hold_fraction


def test_dominant_frequency_and_segment_phases():
    t = np.arange(0, 4, 0.05)
    hz, rhythm = dominant_frequency(np.sin(2 * np.pi * 3 * t), 20.0)
    assert 2.5 <= hz <= 3.5 and rhythm > 0.8
    speed = np.array([0] * 10 + [1] * 10 + [0] * 20, dtype=float)
    onsets, hold, sustained = segment_phases(speed, 0.05, move_threshold=0.5)
    assert onsets == 1 and hold == pytest.approx(20 / 30) and sustained == pytest.approx(0.5)


def test_flow_helpers():
    flow = np.zeros((8, 8, 2))
    flow[..., 0] = 1.0
    mean, std, consistency = flow_statistics(flow)
    assert mean == pytest.approx(1.0) and std == pytest.approx(0.0)
    # Consistency uses only vectors above the mean; a uniform field has none.
    assert consistency == 0.0
    series = FlowSeriesAnalyzer(rate_hz=20, seconds=2)
    for i in range(40):
        dominant, hf = series.push(0.5 + 0.5 * math.sin(2 * math.pi * 6 * i / 20))
    assert 5 <= dominant <= 7 and hf > 0.8
    proxy = LandmarkFlowProxy(rate_hz=20)
    pts = np.random.default_rng(0).uniform(size=(30, 2))
    first = proxy.update(pts, 1.0)
    second = proxy.update(pts + np.array([0.01, 0.0]), 1.0)
    assert first.mag_mean == 0.0 and second.mag_mean == pytest.approx(0.01)


def test_frame_features_validation_and_mapping():
    frame = FrameFeatures.from_mapping(0.0, {"ear_left": 0.3, "ear_right": 0.2})
    assert frame["ear_mean"] == pytest.approx(0.25)
    with pytest.raises(KeyError):
        FrameFeatures.from_mapping(0.0, {"nope": 1.0})
    with pytest.raises(ValueError):
        FrameFeatures(0.0, np.full(FRAME_FEATURE_COUNT, np.nan))
    with pytest.raises(ValueError):
        FrameFeatures(0.0, np.zeros(3))


def test_window_features_shape_and_reference_values():
    frames = np.zeros((50, FRAME_FEATURE_COUNT))
    frames[:, FRAME_INDEX["ear_mean"]] = 0.3
    frames[10:14, FRAME_INDEX["ear_mean"]] = 0.05
    frames[30:34, FRAME_INDEX["ear_mean"]] = 0.05
    frames[:, FRAME_INDEX["head_yaw"]] = np.linspace(0, 10, 50)
    vector = window_features(frames, rate_hz=20, open_ear=0.3)
    assert vector.shape == (WINDOW_FEATURE_COUNT,)
    assert vector[WINDOW_FEATURES.index("blink_count")] == 2
    assert vector[WINDOW_FEATURES.index("head_yaw_range")] == pytest.approx(10.0)
    assert vector[WINDOW_FEATURES.index("ear_mean_min")] == pytest.approx(0.05)
    assert np.isfinite(vector).all()


def test_feature_window_ring_buffer_and_sequence_padding():
    window = FeatureWindow(window_frames=4, sequence_frames=6, rate_hz=20)
    assert not window.is_ready
    for i in range(3):
        window.push(FrameFeatures(i * 0.05, np.full(FRAME_FEATURE_COUNT, float(i))))
    assert window.sequence().shape == (6, FRAME_FEATURE_COUNT)
    assert window.sequence()[0, 0] == 0.0  # front padded with the first frame
    window.push(FrameFeatures(0.15, np.zeros(FRAME_FEATURE_COUNT)))
    assert window.is_ready
    window.push(FrameFeatures(0.0, np.zeros(FRAME_FEATURE_COUNT)))  # time reset clears buffer
    assert len(window) == 1
