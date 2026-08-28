from __future__ import annotations

import asyncio
import logging
import math
import statistics
import time
from collections import deque
from collections.abc import Awaitable, Callable, Iterable, Mapping
from contextlib import suppress
from dataclasses import dataclass
from datetime import UTC, datetime
from enum import StrEnum
from types import MappingProxyType
from typing import Protocol, runtime_checkable

from fingerspeak_edge.adapters import TrackingStatus

logger = logging.getLogger(__name__)


class PatientIntent(StrEnum):
    """Bounded movement intents. These are not emotion or medical classifications."""

    blink = "blink"
    look_left = "look_left"
    look_right = "look_right"
    eyebrows_up = "eyebrows_up"
    mouth_open = "mouth_open"


class IntentMonitorState(StrEnum):
    off = "off"
    calibrating = "calibrating"
    monitoring = "monitoring"
    lost = "lost"
    error = "error"


@dataclass(frozen=True, slots=True)
class FaceMovementSample:
    """Normalized local detector output; it intentionally contains no image or landmarks."""

    face_present: bool
    blink: float | None
    gaze_horizontal: float | None
    eyebrows_up: float | None
    mouth_open: float | None

    def __post_init__(self) -> None:
        if not isinstance(self.face_present, bool):
            raise ValueError("face_present must be boolean")
        for name in ("blink", "eyebrows_up", "mouth_open"):
            value = getattr(self, name)
            if value is not None and (not math.isfinite(value) or not 0 <= value <= 1):
                raise ValueError(f"{name} must be null or a finite value from 0 to 1")
        gaze = self.gaze_horizontal
        if gaze is not None and (not math.isfinite(gaze) or not -1 <= gaze <= 1):
            raise ValueError("gaze_horizontal must be null or a finite value from -1 to 1")

    @classmethod
    def neutral(cls, *, face_present: bool = True) -> FaceMovementSample:
        values: tuple[float | None, ...] = (0.05, 0.0, 0.05, 0.04)
        if not face_present:
            values = (None, None, None, None)
        return cls(face_present, *values)

    def complete(self) -> bool:
        return self.face_present and all(
            value is not None
            for value in (self.blink, self.gaze_horizontal, self.eyebrows_up, self.mouth_open)
        )


@runtime_checkable
class FaceIntentDetector(Protocol):
    """Local detector boundary.

    A hardware implementation owns its frames internally and returns only bounded movement scores.
    It must never upload or expose camera frames through this protocol.
    """

    async def start(self) -> None: ...

    async def stop(self) -> None: ...

    async def sample(self) -> FaceMovementSample: ...


class SimulatedFaceIntentDetector:
    """Deterministic, dependency-free detector for tests and explicit CLI demonstrations."""

    def __init__(
        self,
        samples: Iterable[FaceMovementSample] = (),
        *,
        fallback: FaceMovementSample | None = None,
    ) -> None:
        self._samples = deque(samples)
        self._fallback = fallback or FaceMovementSample.neutral()
        self._running = False

    async def start(self) -> None:
        self._running = True

    async def stop(self) -> None:
        self._running = False

    async def sample(self) -> FaceMovementSample:
        if not self._running:
            raise RuntimeError("Simulated face-intent detector is not running.")
        await asyncio.sleep(0)
        return self._samples.popleft() if self._samples else self._fallback


@dataclass(frozen=True, slots=True)
class FaceIntentRule:
    minimum_delta: float
    noise_multiplier: float
    debounce_seconds: float
    hold_seconds: float
    release_ratio: float
    cooldown_seconds: float

    def __post_init__(self) -> None:
        for name in (
            "minimum_delta",
            "noise_multiplier",
            "debounce_seconds",
            "hold_seconds",
            "cooldown_seconds",
        ):
            value = getattr(self, name)
            if not math.isfinite(value) or value < 0:
                raise ValueError(f"{name} must be a non-negative finite number")
        if not math.isfinite(self.release_ratio) or not 0 <= self.release_ratio < 1:
            raise ValueError("release_ratio must be at least 0 and below 1")


# Total debounce + hold preserves the default patient phrase dwell: 0.65, 0.65, 0.75,
# 1.0, and 1.5 seconds respectively. mouth_open is the default emergency mapping.
DEFAULT_INTENT_RULES: Mapping[PatientIntent, FaceIntentRule] = MappingProxyType(
    {
        PatientIntent.blink: FaceIntentRule(0.32, 4, 0.08, 0.57, 0.45, 0.9),
        PatientIntent.look_left: FaceIntentRule(0.22, 4, 0.12, 0.53, 0.5, 0.9),
        PatientIntent.look_right: FaceIntentRule(0.22, 4, 0.12, 0.63, 0.5, 0.9),
        PatientIntent.eyebrows_up: FaceIntentRule(0.18, 4, 0.12, 0.88, 0.5, 0.9),
        PatientIntent.mouth_open: FaceIntentRule(0.24, 4, 0.20, 1.30, 0.5, 0.9),
    }
)


@dataclass(frozen=True, slots=True)
class MetricBaseline:
    center: float
    noise: float


@dataclass(frozen=True, slots=True)
class NeutralFaceBaseline:
    sample_count: int
    blink: MetricBaseline
    gaze_horizontal: MetricBaseline
    eyebrows_up: MetricBaseline
    mouth_open: MetricBaseline


@dataclass(frozen=True, slots=True)
class PatientIntentDetection:
    intent: PatientIntent
    confidence: float
    detected_at: datetime

    def __post_init__(self) -> None:
        if not math.isfinite(self.confidence) or not 0 <= self.confidence <= 1:
            raise ValueError("confidence must be from 0 to 1")
        if self.detected_at.tzinfo is None or self.detected_at.utcoffset() is None:
            raise ValueError("detected_at must include a timezone")


def build_neutral_baseline(
    samples: Iterable[FaceMovementSample], *, minimum_samples: int = 15
) -> NeutralFaceBaseline:
    if not 1 <= minimum_samples <= 300:
        raise ValueError("minimum_samples must be between 1 and 300")
    complete = [sample for sample in samples if sample.complete()]
    if len(complete) < minimum_samples:
        raise ValueError(
            f"neutral calibration needs {minimum_samples} complete samples; got {len(complete)}"
        )

    def metric(name: str) -> MetricBaseline:
        values = [float(getattr(sample, name)) for sample in complete]
        center = statistics.median(values)
        deviation = statistics.median(abs(value - center) for value in values)
        return MetricBaseline(center=center, noise=max(1.4826 * deviation, 0.0001))

    return NeutralFaceBaseline(
        sample_count=len(complete),
        blink=metric("blink"),
        gaze_horizontal=metric("gaze_horizontal"),
        eyebrows_up=metric("eyebrows_up"),
        mouth_open=metric("mouth_open"),
    )


class CalibratedFaceIntentMachine:
    """One-shot calibrated movement state machine with release-before-rearm."""

    def __init__(
        self,
        baseline: NeutralFaceBaseline,
        *,
        rules: Mapping[PatientIntent, FaceIntentRule] = DEFAULT_INTENT_RULES,
    ) -> None:
        if set(rules) != set(PatientIntent):
            raise ValueError("rules must define every patient intent exactly once")
        self._baseline = baseline
        self._rules = dict(rules)
        self._candidate: PatientIntent | None = None
        self._candidate_since = 0.0
        self._locked: PatientIntent | None = None
        self._release_observed = False
        self._cooldown_until = 0.0
        self._last_now = float("-inf")

    def reset(self) -> None:
        self._candidate = None
        self._candidate_since = 0.0
        self._locked = None
        self._release_observed = False
        self._cooldown_until = 0.0
        self._last_now = float("-inf")

    def step(
        self,
        sample: FaceMovementSample,
        *,
        now: float,
        detected_at: datetime,
    ) -> PatientIntentDetection | None:
        if not math.isfinite(now):
            raise ValueError("intent timestamp must be finite")
        effective_now = max(now, self._last_now)
        self._last_now = effective_now
        ratios = self._activation_ratios(sample)

        if not sample.face_present:
            self._candidate = None
            return None

        if self._locked is not None:
            rule = self._rules[self._locked]
            if ratios[self._locked] <= rule.release_ratio:
                self._release_observed = True
            if effective_now < self._cooldown_until or not self._release_observed:
                return None
            self._locked = None
            self._release_observed = False
            return None

        if self._candidate is not None:
            rule = self._rules[self._candidate]
            if ratios[self._candidate] < rule.release_ratio:
                self._candidate = None

        if self._candidate is None:
            active = [intent for intent in PatientIntent if ratios[intent] >= 1]
            if not active:
                return None
            self._candidate = max(active, key=ratios.__getitem__)
            self._candidate_since = effective_now

        intent = self._candidate
        rule = self._rules[intent]
        required = rule.debounce_seconds + rule.hold_seconds
        if effective_now - self._candidate_since < required:
            return None

        ratio = ratios[intent]
        detection = PatientIntentDetection(
            intent=intent,
            confidence=min(1.0, max(0.0, ratio / 2)),
            detected_at=detected_at,
        )
        self._locked = intent
        self._release_observed = False
        self._cooldown_until = effective_now + rule.cooldown_seconds
        self._candidate = None
        return detection

    def _activation_ratios(
        self, sample: FaceMovementSample
    ) -> dict[PatientIntent, float]:
        if not sample.face_present:
            return {intent: 0.0 for intent in PatientIntent}

        def positive(value: float | None, baseline: MetricBaseline) -> float | None:
            return None if value is None else max(0.0, value - baseline.center)

        def negative(value: float | None, baseline: MetricBaseline) -> float | None:
            return None if value is None else max(0.0, baseline.center - value)

        deltas = {
            PatientIntent.blink: positive(sample.blink, self._baseline.blink),
            PatientIntent.look_left: negative(
                sample.gaze_horizontal, self._baseline.gaze_horizontal
            ),
            PatientIntent.look_right: positive(
                sample.gaze_horizontal, self._baseline.gaze_horizontal
            ),
            PatientIntent.eyebrows_up: positive(
                sample.eyebrows_up, self._baseline.eyebrows_up
            ),
            PatientIntent.mouth_open: positive(
                sample.mouth_open, self._baseline.mouth_open
            ),
        }
        ratios: dict[PatientIntent, float] = {}
        baselines = {
            PatientIntent.blink: self._baseline.blink,
            PatientIntent.look_left: self._baseline.gaze_horizontal,
            PatientIntent.look_right: self._baseline.gaze_horizontal,
            PatientIntent.eyebrows_up: self._baseline.eyebrows_up,
            PatientIntent.mouth_open: self._baseline.mouth_open,
        }
        for intent, delta in deltas.items():
            if delta is None:
                ratios[intent] = 0.0
                continue
            rule = self._rules[intent]
            threshold = max(
                rule.minimum_delta,
                baselines[intent].noise * rule.noise_multiplier,
                0.000001,
            )
            ratios[intent] = max(0.0, delta / threshold)
        return ratios


@dataclass(frozen=True, slots=True)
class IntentMonitorSettings:
    calibration_samples: int = 30
    sample_interval_seconds: float = 0.1
    lost_after_samples: int = 5

    def __post_init__(self) -> None:
        if not 5 <= self.calibration_samples <= 300:
            raise ValueError("calibration_samples must be between 5 and 300")
        if not math.isfinite(self.sample_interval_seconds) or not (
            0.02 <= self.sample_interval_seconds <= 1
        ):
            raise ValueError("sample_interval_seconds must be from 0.02 to 1")
        if not 1 <= self.lost_after_samples <= 100:
            raise ValueError("lost_after_samples must be between 1 and 100")


IntentListener = Callable[[PatientIntentDetection], Awaitable[None]]


class PatientIntentMonitor:
    """Calibrates and monitors detector scores in a cancellable background task."""

    def __init__(
        self,
        detector: FaceIntentDetector,
        *,
        settings: IntentMonitorSettings | None = None,
        monotonic_clock: Callable[[], float] | None = None,
        wall_clock: Callable[[], datetime] | None = None,
    ) -> None:
        self.detector = detector
        self.settings = settings or IntentMonitorSettings()
        self._monotonic = monotonic_clock or time.monotonic
        self._wall_clock = wall_clock or (lambda: datetime.now(UTC))
        self._state = IntentMonitorState.off
        self._calibration_progress = 0.0
        self._task: asyncio.Task[None] | None = None

    @property
    def state(self) -> IntentMonitorState:
        return self._state

    @property
    def calibration_progress(self) -> float:
        return self._calibration_progress

    @property
    def tracking_status(self) -> TrackingStatus:
        return {
            IntentMonitorState.off: TrackingStatus.paused,
            IntentMonitorState.calibrating: TrackingStatus.paused,
            IntentMonitorState.monitoring: TrackingStatus.tracking,
            IntentMonitorState.lost: TrackingStatus.lost,
            IntentMonitorState.error: TrackingStatus.error,
        }[self._state]

    async def start(self, listener: IntentListener) -> None:
        if self._task is not None:
            raise RuntimeError("patient intent monitor is already running")
        await self.detector.start()
        self._state = IntentMonitorState.calibrating
        self._calibration_progress = 0.0
        self._task = asyncio.create_task(self._run(listener), name="patient-intent-monitor")

    async def stop(self) -> None:
        task = self._task
        self._task = None
        if task is not None:
            task.cancel()
            with suppress(asyncio.CancelledError):
                await task
        await self.detector.stop()
        self._state = IntentMonitorState.off
        self._calibration_progress = 0.0

    async def _run(self, listener: IntentListener) -> None:
        try:
            calibration: list[FaceMovementSample] = []
            while len(calibration) < self.settings.calibration_samples:
                sample = await self.detector.sample()
                if sample.complete():
                    calibration.append(sample)
                    self._calibration_progress = (
                        len(calibration) / self.settings.calibration_samples
                    )
                await asyncio.sleep(self.settings.sample_interval_seconds)

            baseline = build_neutral_baseline(
                calibration, minimum_samples=self.settings.calibration_samples
            )
            machine = CalibratedFaceIntentMachine(baseline)
            self._state = IntentMonitorState.monitoring
            missing_samples = 0
            while True:
                sample = await self.detector.sample()
                if sample.face_present:
                    missing_samples = 0
                    self._state = IntentMonitorState.monitoring
                else:
                    missing_samples += 1
                    if missing_samples >= self.settings.lost_after_samples:
                        self._state = IntentMonitorState.lost
                detection = machine.step(
                    sample,
                    now=self._monotonic(),
                    detected_at=self._wall_clock(),
                )
                if detection is not None:
                    await listener(detection)
                await asyncio.sleep(self.settings.sample_interval_seconds)
        except asyncio.CancelledError:
            raise
        except Exception:
            self._state = IntentMonitorState.error
            logger.exception("Local patient-intent monitoring stopped after a detector failure.")


def sample_for_intent(
    intent: PatientIntent, *, strength: float = 0.9
) -> FaceMovementSample:
    if not math.isfinite(strength) or not 0 <= strength <= 1:
        raise ValueError("strength must be from 0 to 1")
    values = {
        "blink": 0.05,
        "gaze_horizontal": 0.0,
        "eyebrows_up": 0.05,
        "mouth_open": 0.04,
    }
    if intent is PatientIntent.look_left:
        values["gaze_horizontal"] = -strength
    elif intent is PatientIntent.look_right:
        values["gaze_horizontal"] = strength
    else:
        values[intent.value] = strength
    return FaceMovementSample(face_present=True, **values)


def simulated_intent_script(
    intent: PatientIntent | None,
    *,
    calibration_samples: int,
    sample_interval_seconds: float,
    quiet_seconds: float = 1.0,
) -> list[FaceMovementSample]:
    settings = IntentMonitorSettings(
        calibration_samples=calibration_samples,
        sample_interval_seconds=sample_interval_seconds,
    )
    script = [FaceMovementSample.neutral()] * settings.calibration_samples
    if intent is None:
        return script
    quiet_count = max(1, math.ceil(quiet_seconds / settings.sample_interval_seconds))
    rule = DEFAULT_INTENT_RULES[intent]
    active_count = math.ceil(
        (rule.debounce_seconds + rule.hold_seconds + settings.sample_interval_seconds)
        / settings.sample_interval_seconds
    )
    script.extend([FaceMovementSample.neutral()] * quiet_count)
    script.extend([sample_for_intent(intent)] * active_count)
    script.extend([FaceMovementSample.neutral()] * quiet_count)
    return script
