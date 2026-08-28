from __future__ import annotations

import asyncio
from collections import deque
from datetime import UTC, datetime

import pytest

from fingerspeak_edge.adapters import TrackingStatus
from fingerspeak_edge.intent_monitor import (
    CalibratedFaceIntentMachine,
    FaceIntentRule,
    FaceMovementSample,
    IntentMonitorSettings,
    IntentMonitorState,
    PatientIntent,
    PatientIntentMonitor,
    build_neutral_baseline,
    sample_for_intent,
)


def _fast_rules() -> dict[PatientIntent, FaceIntentRule]:
    rule = FaceIntentRule(
        minimum_delta=0.2,
        noise_multiplier=0,
        debounce_seconds=0.1,
        hold_seconds=0.2,
        release_ratio=0.5,
        cooldown_seconds=0.5,
    )
    return {intent: rule for intent in PatientIntent}


def test_neutral_calibration_ignores_incomplete_samples_and_uses_robust_center() -> None:
    samples = [
        FaceMovementSample.neutral(face_present=False),
        FaceMovementSample(True, 0.04, -0.01, 0.04, 0.03),
        FaceMovementSample(True, 0.05, 0.00, 0.05, 0.04),
        FaceMovementSample(True, 0.06, 0.01, 0.06, 0.05),
        FaceMovementSample(True, 0.05, 0.00, 0.05, 0.04),
        FaceMovementSample(True, 0.05, 0.00, 0.05, 0.04),
        # A complete outlier must not drag a neutral center away from the median.
        FaceMovementSample(True, 0.95, 0.90, 0.90, 0.90),
    ]

    baseline = build_neutral_baseline(samples, minimum_samples=5)

    assert baseline.sample_count == 6
    assert baseline.blink.center == pytest.approx(0.05)
    assert baseline.gaze_horizontal.center == pytest.approx(0.0)
    assert baseline.eyebrows_up.center == pytest.approx(0.05)
    assert baseline.mouth_open.center == pytest.approx(0.04)
    assert baseline.blink.noise > 0

    with pytest.raises(ValueError, match="needs 7 complete samples; got 6"):
        build_neutral_baseline(samples, minimum_samples=7)


def test_dwell_resets_and_detection_requires_release_and_cooldown_to_rearm() -> None:
    baseline = build_neutral_baseline([FaceMovementSample.neutral()] * 5, minimum_samples=5)
    machine = CalibratedFaceIntentMachine(baseline, rules=_fast_rules())
    active = sample_for_intent(PatientIntent.blink)
    neutral = FaceMovementSample.neutral()
    detected_at = datetime(2026, 8, 22, 12, 0, tzinfo=UTC)

    assert machine.step(active, now=0.00, detected_at=detected_at) is None
    # Falling below the release threshold cancels the first partial dwell.
    assert machine.step(neutral, now=0.25, detected_at=detected_at) is None
    assert machine.step(active, now=0.26, detected_at=detected_at) is None
    assert machine.step(active, now=0.55, detected_at=detected_at) is None

    first = machine.step(active, now=0.56, detected_at=detected_at)
    assert first is not None
    assert first.intent is PatientIntent.blink
    assert 0 <= first.confidence <= 1

    # A sustained gesture cannot repeat, even after cooldown, until neutral release occurs.
    assert machine.step(active, now=1.20, detected_at=detected_at) is None
    assert machine.step(neutral, now=1.21, detected_at=detected_at) is None
    assert machine.step(active, now=1.22, detected_at=detected_at) is None
    assert machine.step(active, now=1.51, detected_at=detected_at) is None

    second = machine.step(active, now=1.52, detected_at=detected_at)
    assert second is not None
    assert second.intent is PatientIntent.blink


class _RecordingDetector:
    def __init__(
        self,
        samples: list[FaceMovementSample],
        *,
        fallback: FaceMovementSample,
    ) -> None:
        self._samples = deque(samples)
        self._fallback = fallback
        self.running = False
        self.start_calls = 0
        self.stop_calls = 0
        self.fallback_calls = 0
        self.fallback_sampled = asyncio.Event()

    async def start(self) -> None:
        self.start_calls += 1
        self.running = True

    async def stop(self) -> None:
        self.stop_calls += 1
        self.running = False

    async def sample(self) -> FaceMovementSample:
        if not self.running:
            raise RuntimeError("detector is not running")
        await asyncio.sleep(0)
        if self._samples:
            return self._samples.popleft()
        self.fallback_calls += 1
        # The state is already lost after two absent samples; signal on the next sample so
        # the monitor has completed the state transition before the test resumes.
        if self.fallback_calls >= 3:
            self.fallback_sampled.set()
        return self._fallback


class _IncrementingClock:
    def __init__(self, step: float) -> None:
        self._value = 0.0
        self._step = step

    def __call__(self) -> float:
        value = self._value
        self._value += self._step
        return value


@pytest.mark.asyncio
async def test_monitor_lifecycle_calibrates_emits_semantic_event_and_reports_loss() -> None:
    neutral = FaceMovementSample.neutral()
    detector = _RecordingDetector(
        [neutral] * 5 + [sample_for_intent(PatientIntent.blink)] * 3,
        fallback=FaceMovementSample.neutral(face_present=False),
    )
    detected_at = datetime(2026, 8, 22, 12, 0, tzinfo=UTC)
    monitor = PatientIntentMonitor(
        detector,
        settings=IntentMonitorSettings(
            calibration_samples=5,
            sample_interval_seconds=0.02,
            lost_after_samples=2,
        ),
        monotonic_clock=_IncrementingClock(0.35),
        wall_clock=lambda: detected_at,
    )
    detections = []
    detected = asyncio.Event()

    async def listener(detection) -> None:
        detections.append(detection)
        detected.set()

    await monitor.start(listener)
    try:
        assert detector.running is True
        assert detector.start_calls == 1
        assert monitor.state is IntentMonitorState.calibrating
        assert monitor.tracking_status is TrackingStatus.paused

        await asyncio.wait_for(detected.wait(), timeout=5)
        assert detections[0].intent is PatientIntent.blink
        assert detections[0].detected_at == detected_at
        assert monitor.calibration_progress == pytest.approx(1.0)

        await asyncio.wait_for(detector.fallback_sampled.wait(), timeout=5)
        assert monitor.tracking_status is TrackingStatus.lost
    finally:
        await monitor.stop()

    assert detector.running is False
    assert detector.stop_calls == 1
    assert monitor.state is IntentMonitorState.off
    assert monitor.calibration_progress == 0
    assert monitor.tracking_status is TrackingStatus.paused
