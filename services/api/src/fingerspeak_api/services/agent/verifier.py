"""Verification and Self-Correction Engine for NeuroBridge Asha.

Evaluates draft agent outputs across 4 clinical & assistive dimensions:
1. Clinical Safety (no ungrounded diagnosis/prescription, proper emergency escalation).
2. Goal / Intent Fulfillment (verifies all user-requested actions were executed).
3. RAG Factual Grounding (verifies claims are supported by retrieved clinical chunks).
4. Spoken Voice Usability (conciseness, tone, and AAC readability).
"""

from __future__ import annotations

import re
import unicodedata
from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import Any

from fingerspeak_api.services.agent.tools import ToolExecution

# Prohibited medical diagnosing and prescribing phrases
_DIAGNOSIS_PATTERNS = tuple(
    re.compile(p, re.I)
    for p in (
        r"\byou (?:have|are suffering from|have developed|contracted)\b",
        r"\bi diagnose you with\b",
        r"\bmy diagnosis is\b",
        r"\btake \d+\s*(?:mg|ml|tablets?|pills?)\b",
        r"\bi prescribe\b",
        r"\bstart taking\b",
    )
)

# False emergency claims (claiming an ambulance/police was physically called by the AI)
_FALSE_EMERGENCY_CLAIMS = tuple(
    re.compile(p, re.I)
    for p in (
        r"\bi (?:have )?called (?:an? )?ambulance\b",
        r"\bambulance is on the way\b",
        r"\bi dispatched emergency services\b",
        r"\bparamedics are en route\b",
        r"\bi dialed 911\b",
    )
)

# Urgent trigger patterns requiring emergency protocol escalation
_URGENT_TRIGGERS = tuple(
    re.compile(p, re.I)
    for p in (
        r"\b(?:cannot|can't) breathe\b",
        r"\bchoking\b",
        r"\bseizure\b",
        r"\bconvuls\w*\b",
        r"\bsevere chest pain\b",
        r"\bautonomic dysreflexia\b",
    )
)


@dataclass(slots=True)
class VerificationResult:
    is_verified: bool
    safety_passed: bool
    goal_fulfilled: bool
    grounding_score: float
    critique_notes: str
    missing_actions: list[str] = field(default_factory=list)
    remediation_suggestion: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "is_verified": self.is_verified,
            "safety_passed": self.safety_passed,
            "goal_fulfilled": self.goal_fulfilled,
            "grounding_score": round(self.grounding_score, 2),
            "critique_notes": self.critique_notes,
        }


def _tokenize(text: str) -> set[str]:
    normalized = unicodedata.normalize("NFKC", text).lower()
    return set(re.findall(r"\w{3,}", normalized))


class VerificationEngine:
    """Evaluates agent execution quality and provides self-correction critique."""

    def evaluate(
        self,
        user_message: str,
        draft_reply: str,
        actions_executed: Sequence[ToolExecution],
        rag_snippets: Sequence[str] = (),
    ) -> VerificationResult:
        critique_reasons: list[str] = []
        missing_actions: list[str] = []

        # -------------------------------------------------------------
        # 1. Safety Check
        # -------------------------------------------------------------
        safety_passed = True

        for pat in _DIAGNOSIS_PATTERNS:
            if pat.search(draft_reply):
                safety_passed = False
                critique_reasons.append(
                    "Draft contains prohibited medical diagnosis or prescription statement."
                )
                break

        for pat in _FALSE_EMERGENCY_CLAIMS:
            if pat.search(draft_reply):
                # Only acceptable if a physical emergency dispatch tool was genuinely triggered
                has_emergency_tool = any(
                    ex.tool_name == "trigger_caregiver_alert"
                    and ex.parameters.get("severity") == "emergency"
                    and ex.success
                    for ex in actions_executed
                )
                if not has_emergency_tool:
                    safety_passed = False
                    critique_reasons.append(
                        "Draft falsely claims emergency services were contacted."
                    )
                    break

        # Check emergency escalation if user message is urgent
        is_urgent_user = any(pat.search(user_message) for pat in _URGENT_TRIGGERS)
        if is_urgent_user:
            has_urgent_action = any(
                ex.tool_name in ("trigger_caregiver_alert", "lookup_clinical_guidance")
                for ex in actions_executed
            )
            advised_protocol = any(
                kw in draft_reply.lower()
                for kw in (
                    "caregiver",
                    "emergency",
                    "ambulance",
                    "911",
                    "first aid",
                    "airway",
                    "side",
                )
            )
            if not has_urgent_action and not advised_protocol:
                safety_passed = False
                critique_reasons.append(
                    "Urgent distress reported but emergency guidance or alert action was omitted."
                )
                missing_actions.append("trigger_caregiver_alert")

        # -------------------------------------------------------------
        # 2. Goal / Intent Fulfillment Check
        # -------------------------------------------------------------
        goal_fulfilled = True
        normalized_msg = user_message.lower()
        executed_tool_names = {ex.tool_name for ex in actions_executed if ex.success}

        # Intent: Alert caregiver
        if any(
            w in normalized_msg
            for w in ("call caregiver", "alert caregiver", "call nurse", "tell caregiver")
        ):
            if "trigger_caregiver_alert" not in executed_tool_names:
                goal_fulfilled = False
                critique_reasons.append(
                    "User requested caregiver contact, but 'trigger_caregiver_alert' was not executed."
                )
                missing_actions.append("trigger_caregiver_alert")

        # Intent: Wheelchair screen display
        if any(
            w in normalized_msg
            for w in ("show on screen", "display on wheelchair", "write to display")
        ):
            if "send_wheelchair_caption" not in executed_tool_names:
                goal_fulfilled = False
                critique_reasons.append(
                    "User requested screen display update, but 'send_wheelchair_caption' was not executed."
                )
                missing_actions.append("send_wheelchair_caption")

        # Intent: Battery / Hardware check
        if any(
            w in normalized_msg
            for w in ("battery", "camera status", "check pi", "check wheelchair")
        ):
            if "check_device_telemetry" not in executed_tool_names:
                goal_fulfilled = False
                critique_reasons.append(
                    "User asked about device/battery status, but 'check_device_telemetry' was not executed."
                )
                missing_actions.append("check_device_telemetry")

        # Intent: Water / Hydration / Reposition
        if any(
            w in normalized_msg for w in ("thirsty", "need water", "reposition", "pressure sore")
        ):
            if "manage_care_routine" not in executed_tool_names:
                goal_fulfilled = False
                critique_reasons.append(
                    "User requested care routine action (water/repositioning), but 'manage_care_routine' was not executed."
                )
                missing_actions.append("manage_care_routine")

        # -------------------------------------------------------------
        # 3. Grounding Verification
        # -------------------------------------------------------------
        grounding_score = 1.0
        if rag_snippets:
            reply_tokens = _tokenize(draft_reply)
            all_rag_text = " ".join(rag_snippets)
            rag_tokens = _tokenize(all_rag_text)

            if reply_tokens and rag_tokens:
                supported_tokens = reply_tokens.intersection(rag_tokens)
                grounding_score = len(supported_tokens) / max(len(reply_tokens), 1)
                # Normal clinical grounding expectation is >= 0.20 overlap with snippet terminology
                if grounding_score < 0.15 and len(reply_tokens) > 15:
                    critique_reasons.append(
                        f"Low factual grounding ({grounding_score:.2f}) with clinical knowledge."
                    )

        # -------------------------------------------------------------
        # 4. Spoken Voice Usability Check
        # -------------------------------------------------------------
        if len(draft_reply) > 800:
            critique_reasons.append(
                "Reply is too long for spoken AAC communication. Keep to 1-3 sentences."
            )

        is_verified = (
            safety_passed
            and goal_fulfilled
            and (len(critique_reasons) == 0 or grounding_score >= 0.15)
        )
        critique_notes = (
            "; ".join(critique_reasons)
            if critique_reasons
            else "All safety, goal fulfillment, and grounding checks passed."
        )

        remediation = ""
        if not is_verified:
            steps = []
            if not safety_passed:
                steps.append(
                    "Remove any diagnostic/prescriptive phrasing. Advise confirmed emergency path."
                )
            if missing_actions:
                steps.append(f"Execute required missing tool(s): {', '.join(missing_actions)}.")
            if len(draft_reply) > 800:
                steps.append("Condense speech to 2-3 reassuring spoken sentences.")
            remediation = " ".join(steps)

        return VerificationResult(
            is_verified=is_verified,
            safety_passed=safety_passed,
            goal_fulfilled=goal_fulfilled,
            grounding_score=grounding_score,
            critique_notes=critique_notes[:500],
            missing_actions=missing_actions,
            remediation_suggestion=remediation,
        )
