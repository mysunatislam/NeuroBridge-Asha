"""End-to-end runtime pipeline (NumPy only).

    FrameFeatures -> FeatureWindow -> IntentRuntime (Phase 1)
                                   -> TemporalRuntime (Phase 2)
                                   -> AbnormalRuntime (Phase 3)
                                   -> PatientProfile prototypes / normaliser
                                   -> ConfidenceVerificationEngine -> ActionEvent

``IntentPipeline.push`` is called once per resampled frame and returns a
:class:`Verdict` when a decision was made (execute / confirm / alert / cancel) or
``None`` while nothing happens. Structured events for the optional Gemini layer are
produced by :meth:`IntentPipeline.event_payload`.
"""

from __future__ import annotations

import json
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np

from .calibration import PatientProfile
from .features.window import FeatureWindow, FrameFeatures
from .models.abnormal import AbnormalRuntime
from .models.intent_classifier import IntentRuntime
from .models.temporal import TemporalRuntime
from .schema import (
    BUNDLE_SCHEMA_VERSION,
    DEFAULT_COMMAND_SIGNALS,
    FRAME_RATE_HZ,
    SEQUENCE_FRAMES,
    WINDOW_FRAMES,
    CommandClass,
)
from .verification import ConfidenceVerificationEngine, Decision, Evidence, Verdict


@dataclass(slots=True)
class ModelBundle:
    manifest: dict[str, Any]
    intent: IntentRuntime
    temporal: TemporalRuntime
    abnormal: AbnormalRuntime

    @classmethod
    def load(cls, directory: str | Path) -> ModelBundle:
        root = Path(directory)
        manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
        if manifest.get("schema_version") != BUNDLE_SCHEMA_VERSION:
            raise ValueError("unsupported model bundle schema")
        intent = IntentRuntime(
            json.loads((root / manifest["files"]["intent_json"]).read_text(encoding="utf-8"))
        )
        temporal = TemporalRuntime(
            json.loads((root / manifest["files"]["temporal_json"]).read_text(encoding="utf-8"))
        )
        abnormal = AbnormalRuntime(
            json.loads((root / manifest["files"]["abnormal_json"]).read_text(encoding="utf-8"))
        )
        return cls(manifest, intent, temporal, abnormal)


@dataclass(slots=True)
class PipelineEvent:
    t_s: float
    verdict: Verdict
    intent: dict[str, Any]
    temporal: dict[str, Any]
    abnormal: dict[str, Any]

    def to_dict(self) -> dict[str, Any]:
        return {
            "t_s": round(self.t_s, 3),
            "verdict": self.verdict.to_dict(),
            "intent": self.intent,
            "temporal": self.temporal,
            "abnormal": self.abnormal,
        }


@dataclass(slots=True)
class IntentPipeline:
    bundle: ModelBundle
    profile: PatientProfile
    engine: ConfidenceVerificationEngine = field(default_factory=ConfidenceVerificationEngine)
    decision_interval_s: float = 0.25
    history_size: int = 200
    window: FeatureWindow = field(init=False)
    history: deque[PipelineEvent] = field(init=False)
    _last_decision_t: float = field(init=False, default=-1e9)

    def __post_init__(self) -> None:
        self.window = FeatureWindow(
            window_frames=WINDOW_FRAMES, sequence_frames=SEQUENCE_FRAMES, rate_hz=FRAME_RATE_HZ
        )
        self.history = deque(maxlen=self.history_size)
        thresholds = self.profile.gesture_thresholds
        self.engine.ignore_below = float(
            thresholds.get("intent_ignore_below", self.engine.ignore_below)
        )
        self.engine.execute_at = float(thresholds.get("intent_execute_at", self.engine.execute_at))
        self.engine.prototype_weight = float(
            thresholds.get("prototype_weight", self.engine.prototype_weight)
        )
        self.engine.confirmation_window_s = float(
            thresholds.get("confirmation_window_s", self.engine.confirmation_window_s)
        )
        involuntary = self.profile.involuntary_profile
        self.bundle.abnormal.rest_hf_ratio = float(
            involuntary.get("hf_ratio_rest", self.bundle.abnormal.rest_hf_ratio)
        )
        self.bundle.abnormal.rest_rhythmicity = float(
            involuntary.get("head_rhythmicity_rest", self.bundle.abnormal.rest_rhythmicity)
        )

    # -- per-frame entry point -------------------------------------------------------

    def push(self, frame: FrameFeatures) -> Verdict | None:
        self.window.push(frame)
        if not self.window.is_ready:
            return None
        if frame.t_s - self._last_decision_t < self.decision_interval_s:
            return None
        self._last_decision_t = frame.t_s
        return self._decide(frame.t_s)

    def _decide(self, t_s: float) -> Verdict | None:
        features = self.window.features(open_ear=self.profile.open_ear())
        sequence = self.profile.normalize(self.window.sequence())
        intent = self.bundle.intent.predict(features)
        command, p_command = self.bundle.temporal.predict(sequence, normalized=True)
        abnormal = self.bundle.abnormal.predict(features)
        p_prototype = self.profile.intentional_prototype_probability(features)
        evidence = Evidence(
            command=command,
            p_command=p_command,
            p_intentional=intent.p_intentional,
            intent_label=intent.label,
            p_prototype=p_prototype,
            p_abnormal=abnormal.p_abnormal,
            abnormal_label=abnormal.label,
            t_s=t_s,
        )
        verdict = self.engine.evaluate(evidence)
        if verdict.decision in (
            Decision.execute,
            Decision.confirm,
            Decision.alert,
            Decision.cancel,
        ):
            self.history.append(
                PipelineEvent(
                    t_s,
                    verdict,
                    intent.to_dict(),
                    {"command": command, "p_command": round(p_command, 4)},
                    abnormal.to_dict(),
                )
            )
            return verdict
        return None

    # -- app integration helpers -----------------------------------------------------

    def signal_for(self, command: str) -> str | None:
        """Map a verified command pattern to the app's patient-signal kind."""

        if command == CommandClass.non_command.value:
            return None
        return self.profile.command_map.get(command, DEFAULT_COMMAND_SIGNALS.get(command))

    def confirm_by_touch(self, t_s: float) -> Verdict | None:
        verdict = self.engine.confirm_externally(t_s)
        if verdict is not None:
            self.history.append(PipelineEvent(t_s, verdict, {}, {}, {}))
        return verdict

    def event_payload(self, *, patient_history: str = "") -> dict[str, Any]:
        """Structured, camera-free summary for the optional Gemini reasoning layer."""

        latest = self.history[-1] if self.history else None
        recent = [event.to_dict() for event in list(self.history)[-10:]]
        state = "idle"
        if latest is not None:
            if latest.verdict.decision == Decision.alert:
                state = "possible_abnormal_movement"
            elif latest.verdict.decision == Decision.execute:
                state = f"command_{latest.verdict.command}"
            elif latest.verdict.decision == Decision.confirm:
                state = "awaiting_confirmation"
        return {
            "patient_state": state,
            "gesture": latest.verdict.command if latest else None,
            "confidence": round(latest.verdict.confidence, 3) if latest else None,
            "decision": latest.verdict.decision.value if latest else None,
            "patient_history": patient_history,
            "profile": {
                "patient_id": self.profile.patient_id,
                "blink_rate_per_min": round(float(self.profile.blink.get("rate_per_min", 0.0)), 1),
                "command_map": self.profile.command_map,
            },
            "recent_events": recent,
        }

    def reset(self) -> None:
        self.window.clear()
        self.engine.reset()
        self.history.clear()
        self._last_decision_t = -1e9


def run_clip(
    pipeline: IntentPipeline, values: np.ndarray, timestamps: np.ndarray | None = None
) -> list[Verdict]:
    """Feed a (T, C) clip through the pipeline and collect the verdicts (tests/demo)."""

    if timestamps is None:
        timestamps = np.arange(values.shape[0]) / FRAME_RATE_HZ
    verdicts: list[Verdict] = []
    for t, row in zip(timestamps, values, strict=False):
        verdict = pipeline.push(FrameFeatures(float(t), np.asarray(row)))
        if verdict is not None:
            verdicts.append(verdict)
    return verdicts
