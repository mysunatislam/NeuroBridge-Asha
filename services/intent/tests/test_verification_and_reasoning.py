from __future__ import annotations

import pytest

from neurobridge_intent.reasoning import GeminiReasoner, ReasoningRequest, offline_summary
from neurobridge_intent.schema import AbnormalClass, CommandClass, IntentClass
from neurobridge_intent.verification import (
    ConfidenceVerificationEngine,
    Decision,
    Evidence,
    fuse_confidence,
)


def evidence(
    command=CommandClass.triple_blink.value,
    p_command=0.95,
    p_intentional=0.9,
    intent_label=IntentClass.intentional.value,
    p_prototype=0.7,
    p_abnormal=0.05,
    abnormal_label=AbnormalClass.normal_voluntary.value,
    t_s=1.0,
):
    return Evidence(
        command,
        p_command,
        p_intentional,
        intent_label,
        p_prototype,
        p_abnormal,
        abnormal_label,
        t_s,
    )


def test_fuse_confidence_monotone_and_bounded():
    high = fuse_confidence(
        p_command=0.98,
        p_intentional=0.95,
        intent_label="intentional",
        p_prototype=0.8,
        p_abnormal=0.02,
    )
    accidental = fuse_confidence(
        p_command=0.98,
        p_intentional=0.95,
        intent_label="accidental",
        p_prototype=0.8,
        p_abnormal=0.02,
    )
    vetoed = fuse_confidence(
        p_command=0.98,
        p_intentional=0.95,
        intent_label="intentional",
        p_prototype=0.8,
        p_abnormal=0.9,
    )
    assert 0.9 <= high <= 1.0
    assert accidental < high
    assert vetoed < 0.2
    with pytest.raises(ValueError):
        fuse_confidence(
            p_command=1.5,
            p_intentional=0.5,
            intent_label="intentional",
            p_prototype=0.5,
            p_abnormal=0.0,
        )


def test_thresholds_execute_confirm_ignore():
    engine = ConfidenceVerificationEngine(prototype_weight=0.4)
    assert engine.evaluate(evidence()).decision == Decision.execute
    engine.reset()
    moderate = engine.evaluate(evidence(p_command=0.8, p_intentional=0.7, p_prototype=0.5, t_s=2.0))
    assert moderate.decision == Decision.confirm
    assert moderate.prompt and moderate.prompt.startswith("Did you mean")
    low = engine.evaluate(
        evidence(
            p_command=0.5, p_intentional=0.5, intent_label="unknown", p_prototype=0.3, t_s=20.0
        )
    )
    assert low.decision in (Decision.ignore, Decision.cancel)


def test_confirmation_flow_confirm_repeat_and_expiry():
    engine = ConfidenceVerificationEngine(confirmation_window_s=5.0)
    asked = engine.evaluate(evidence(p_command=0.8, p_intentional=0.7, p_prototype=0.5, t_s=1.0))
    assert asked.decision == Decision.confirm and engine.pending is not None
    confirmed = engine.evaluate(
        evidence(
            command=CommandClass.double_blink.value,
            p_command=0.85,
            p_intentional=0.7,
            p_prototype=0.5,
            t_s=3.0,
        )
    )
    assert (
        confirmed.decision == Decision.execute
        and confirmed.command == CommandClass.triple_blink.value
    )
    # Expiry cancels.
    engine.reset()
    engine.evaluate(evidence(p_command=0.8, p_intentional=0.7, p_prototype=0.5, t_s=1.0))
    expired = engine.evaluate(
        evidence(command=CommandClass.non_command.value, p_command=0.9, t_s=10.0)
    )
    assert expired.decision == Decision.cancel and engine.pending is None
    # Touch confirmation.
    engine.evaluate(evidence(p_command=0.8, p_intentional=0.7, p_prototype=0.5, t_s=12.0))
    touched = engine.confirm_externally(13.0)
    assert touched is not None and touched.decision == Decision.execute


def test_abnormal_movement_blocks_commands_and_alerts_once_per_cooldown():
    engine = ConfidenceVerificationEngine(cooldown_s=3.0)
    alert = engine.evaluate(
        evidence(p_abnormal=0.9, abnormal_label=AbnormalClass.possible_seizure_like.value, t_s=1.0)
    )
    assert alert.decision == Decision.alert
    again = engine.evaluate(
        evidence(p_abnormal=0.9, abnormal_label=AbnormalClass.possible_seizure_like.value, t_s=2.0)
    )
    assert again.decision == Decision.ignore
    involuntary = engine.evaluate(
        evidence(p_abnormal=0.8, abnormal_label=AbnormalClass.involuntary.value, t_s=10.0)
    )
    assert involuntary.decision == Decision.ignore


def test_execution_cooldown():
    engine = ConfidenceVerificationEngine(cooldown_s=3.0)
    assert engine.evaluate(evidence(t_s=1.0)).decision == Decision.execute
    assert engine.evaluate(evidence(t_s=2.0)).decision == Decision.ignore
    assert engine.evaluate(evidence(t_s=5.0)).decision == Decision.execute


def test_reasoning_rejects_raw_data_and_falls_back_offline(monkeypatch):
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    with pytest.raises(ValueError):
        ReasoningRequest("summarize", {"patient_state": "idle", "landmarks": [[0, 0]]})
    payload = {
        "patient_state": "possible_help_request",
        "gesture": "triple_blink",
        "confidence": 0.91,
        "patient_history": "usually uses triple blink for assistance",
    }
    request = ReasoningRequest("summarize", payload)
    text, used = GeminiReasoner().reason(request)
    assert used is False and "triple blink" in text
    reasoner = GeminiReasoner(api_key="not-a-real-key", timeout_s=0.01)

    def boom(self, request):
        raise TimeoutError("offline")

    monkeypatch.setattr(GeminiReasoner, "_call", boom)
    text, used = reasoner.reason(request)
    assert used is False and reasoner.last_error == "offline"
    assert (
        "abnormal"
        in offline_summary(
            ReasoningRequest("summarize", {"patient_state": "possible_abnormal_movement"})
        ).lower()
        or "involuntary"
        in offline_summary(
            ReasoningRequest("summarize", {"patient_state": "possible_abnormal_movement"})
        ).lower()
    )
