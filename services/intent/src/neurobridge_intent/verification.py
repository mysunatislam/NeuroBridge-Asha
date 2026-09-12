"""Confidence Verification Engine.

    confidence < 0.70          -> ignore
    0.70 <= confidence < 0.90  -> ask for confirmation ("Did you mean help?")
    confidence >= 0.90         -> execute

The fused confidence combines the temporal command probability, the Phase 1
intentional probability, the patient-specific prototype agreement and the abnormal
movement veto. A detected abnormal movement never becomes a command; seizure-like
activity is escalated as an alert instead.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from enum import StrEnum

from .schema import EXECUTE_AT, IGNORE_BELOW, AbnormalClass, CommandClass, IntentClass


class Decision(StrEnum):
    ignore = "ignore"
    confirm = "confirm"
    execute = "execute"
    alert = "alert"
    cancel = "cancel"


@dataclass(frozen=True, slots=True)
class Evidence:
    command: str
    p_command: float
    p_intentional: float
    intent_label: str
    p_prototype: float
    p_abnormal: float
    abnormal_label: str
    t_s: float


@dataclass(frozen=True, slots=True)
class Verdict:
    decision: Decision
    command: str
    confidence: float
    reason: str
    prompt: str | None = None
    evidence: Evidence | None = None

    def to_dict(self) -> dict[str, object]:
        return {
            "decision": self.decision.value,
            "command": self.command,
            "confidence": round(self.confidence, 4),
            "reason": self.reason,
            "prompt": self.prompt,
        }


def fuse_confidence(
    *,
    p_command: float,
    p_intentional: float,
    intent_label: str,
    p_prototype: float,
    p_abnormal: float,
    prototype_weight: float = 0.4,
) -> float:
    """Combine the layers into one bounded confidence.

    * the temporal probability is the backbone;
    * Phase 1 scales it: an ``accidental``/``unknown`` verdict halves or removes it;
    * the patient prototype agreement is blended in with ``prototype_weight``;
    * abnormal probability is a multiplicative veto.
    """

    for name, value in (
        ("p_command", p_command),
        ("p_intentional", p_intentional),
        ("p_prototype", p_prototype),
        ("p_abnormal", p_abnormal),
    ):
        if not (math.isfinite(value) and 0.0 <= value <= 1.0):
            raise ValueError(f"{name} must be within [0, 1]")
    if intent_label == IntentClass.accidental.value:
        gate = 0.5 * p_intentional
    elif intent_label == IntentClass.unknown.value:
        gate = 0.35 + 0.35 * p_intentional
    else:
        gate = 0.75 + 0.25 * p_intentional
    personal = (1.0 - prototype_weight) + prototype_weight * (0.5 + p_prototype)
    personal = min(personal, 1.0 + 0.5 * prototype_weight)
    # A small residual abnormal probability is classifier noise; the veto ramps
    # from no effect at 0.1 to a near-total block at 1.0.
    veto = 1.0 - max(0.0, p_abnormal - 0.1) / 0.9
    fused = p_command * gate * personal * veto
    return float(max(0.0, min(1.0, fused)))


@dataclass(slots=True)
class PendingConfirmation:
    command: str
    confidence: float
    asked_at: float
    expires_at: float


@dataclass(slots=True)
class ConfidenceVerificationEngine:
    ignore_below: float = IGNORE_BELOW
    execute_at: float = EXECUTE_AT
    prototype_weight: float = 0.4
    confirmation_window_s: float = 8.0
    cooldown_s: float = 3.0
    abnormal_alert_threshold: float = 0.6
    confirm_commands: tuple[str, ...] = (
        CommandClass.double_blink.value,
        CommandClass.long_blink.value,
        CommandClass.brow_raise_hold.value,
    )
    prompts: dict[str, str] = field(default_factory=dict)
    pending: PendingConfirmation | None = None
    _last_execution: dict[str, float] = field(default_factory=dict)
    _last_alert_at: float = -1e9

    def __post_init__(self) -> None:
        if not 0.0 < self.ignore_below <= self.execute_at <= 1.0:
            raise ValueError("thresholds must satisfy 0 < ignore_below <= execute_at <= 1")

    def prompt_for(self, command: str) -> str:
        return self.prompts.get(command, f"Did you mean {command.replace('_', ' ')}?")

    def evaluate(self, evidence: Evidence) -> Verdict:
        """Turn one window of evidence into a decision. Stateful (pending confirmations)."""

        # Abnormal movement always takes precedence over any command.
        if (
            evidence.abnormal_label != AbnormalClass.normal_voluntary.value
            and evidence.p_abnormal >= self.abnormal_alert_threshold
        ):
            self.pending = None
            escalate = evidence.abnormal_label in (
                AbnormalClass.possible_seizure_like.value,
                AbnormalClass.possible_spasm.value,
            )
            if escalate and evidence.t_s - self._last_alert_at >= self.cooldown_s:
                self._last_alert_at = evidence.t_s
                return Verdict(
                    Decision.alert,
                    evidence.abnormal_label,
                    evidence.p_abnormal,
                    "abnormal movement detected; commands suppressed",
                    evidence=evidence,
                )
            return Verdict(
                Decision.ignore,
                evidence.abnormal_label,
                evidence.p_abnormal,
                "involuntary movement; not a command",
                evidence=evidence,
            )

        if evidence.command == CommandClass.non_command.value:
            if self.pending is not None and evidence.t_s > self.pending.expires_at:
                expired = self.pending
                self.pending = None
                return Verdict(
                    Decision.cancel,
                    expired.command,
                    expired.confidence,
                    "confirmation window expired",
                    evidence=evidence,
                )
            return Verdict(
                Decision.ignore, evidence.command, 0.0, "no command pattern", evidence=evidence
            )

        confidence = fuse_confidence(
            p_command=evidence.p_command,
            p_intentional=evidence.p_intentional,
            intent_label=evidence.intent_label,
            p_prototype=evidence.p_prototype,
            p_abnormal=evidence.p_abnormal,
            prototype_weight=self.prototype_weight,
        )

        # A pending confirmation is answered by a confirm gesture or by repeating the command.
        if self.pending is not None:
            if evidence.t_s > self.pending.expires_at:
                expired = self.pending
                self.pending = None
                return Verdict(
                    Decision.cancel,
                    expired.command,
                    expired.confidence,
                    "confirmation window expired",
                    evidence=evidence,
                )
            if (
                evidence.command in self.confirm_commands
                or evidence.command == self.pending.command
            ) and confidence >= self.ignore_below:
                confirmed = self.pending
                self.pending = None
                self._last_execution[confirmed.command] = evidence.t_s
                return Verdict(
                    Decision.execute,
                    confirmed.command,
                    max(confirmed.confidence, confidence),
                    "confirmed by patient",
                    evidence=evidence,
                )
            return Verdict(
                Decision.ignore,
                evidence.command,
                confidence,
                "awaiting confirmation",
                evidence=evidence,
            )

        if confidence < self.ignore_below:
            return Verdict(
                Decision.ignore,
                evidence.command,
                confidence,
                "confidence below ignore threshold",
                evidence=evidence,
            )
        last = self._last_execution.get(evidence.command)
        if last is not None and evidence.t_s - last < self.cooldown_s:
            return Verdict(
                Decision.ignore,
                evidence.command,
                confidence,
                "cooldown after execution",
                evidence=evidence,
            )
        if confidence >= self.execute_at:
            self._last_execution[evidence.command] = evidence.t_s
            return Verdict(
                Decision.execute, evidence.command, confidence, "high confidence", evidence=evidence
            )
        self.pending = PendingConfirmation(
            evidence.command, confidence, evidence.t_s, evidence.t_s + self.confirmation_window_s
        )
        return Verdict(
            Decision.confirm,
            evidence.command,
            confidence,
            "moderate confidence; asking for confirmation",
            prompt=self.prompt_for(evidence.command),
            evidence=evidence,
        )

    def confirm_externally(self, t_s: float) -> Verdict | None:
        """Caregiver/touch confirmation of the pending command."""

        if self.pending is None:
            return None
        pending = self.pending
        self.pending = None
        self._last_execution[pending.command] = t_s
        return Verdict(
            Decision.execute,
            pending.command,
            max(pending.confidence, self.execute_at),
            "confirmed by touch",
        )

    def cancel(self) -> None:
        self.pending = None

    def reset(self) -> None:
        self.pending = None
        self._last_execution.clear()
        self._last_alert_at = -1e9
