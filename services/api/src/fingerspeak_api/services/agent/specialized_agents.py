"""Specialized Multi-Agent Quadrant for NeuroBridge Asha.

Implements the 4 autonomous agents:
1. CommunicationAgent: Dialogue, phrase prediction, Bengali/English translation, and AAC scaffolding.
2. HealthMonitoringAgent: Continuous screening of pain grimaces, fatigue, tremors, and spasm patterns.
3. RehabilitationAgent: Interactive step-by-step coaching for physical range-of-motion and speech drills.
4. EmergencyAgent: Autonomous safety escalation (Fall/Spasm/Unresponsive -> Prompt -> Call -> Alert).
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

logger = logging.getLogger("fingerspeak_api.specialized_agents")


# ---------------------------------------------------------------------------
# Communication Agent
# ---------------------------------------------------------------------------


@dataclass(slots=True)
class CommunicationResponse:
    spoken_text: str
    display_caption: str
    target_language: str
    audio_pitch: float = 1.0
    audio_rate: float = 0.9
    suggestions: list[str] = field(default_factory=list)


class CommunicationAgent:
    """Manages natural dialogue, conversational pacing, and multilingual speech."""

    def format_speech(
        self,
        message: str,
        locale: str = "en-US",
        preferred_name: str | None = None,
    ) -> CommunicationResponse:
        name_clause = f"{preferred_name}, " if preferred_name else ""
        is_bengali = locale.startswith("bn") or any(
            ord(c) >= 0x0980 and ord(c) <= 0x09FF for c in message
        )

        if is_bengali:
            display = message
            spoken = f"আমি শুনছি, {name_clause}{message}" if not message.startswith("আমি") else message
            suggestions = ["পানি চাই", "কেয়ারগিভার ডাকুন", "কষ্ট হচ্ছে", "ধন্যবাদ"]
            lang = "bn-BD"
        else:
            display = message
            spoken = f"I'm here with you, {name_clause}{message}" if not message.startswith("I") else message
            suggestions = ["Water please", "Call caregiver", "I feel pain", "Thank you"]
            lang = "en-US"

        return CommunicationResponse(
            spoken_text=spoken,
            display_caption=display,
            target_language=lang,
            suggestions=suggestions,
        )


# ---------------------------------------------------------------------------
# Health Monitoring Agent
# ---------------------------------------------------------------------------


@dataclass(slots=True)
class HealthAssessment:
    pain_level: int  # 0 to 10
    fatigue_detected: bool
    abnormal_movement_detected: bool
    vital_status: str  # "stable", "elevated_risk", "critical"
    clinical_notes: list[str] = field(default_factory=list)
    recommended_action: str | None = None


class HealthMonitoringAgent:
    """Monitors continuous kinematic and facial indicators for pain, fatigue, and distress."""

    def evaluate_signals(
        self,
        *,
        grimace_intensity: float = 0.0,
        tremor_frequency_hz: float = 0.0,
        spasm_detected: bool = False,
        unresponsive_duration_s: float = 0.0,
    ) -> HealthAssessment:
        notes: list[str] = []
        pain_score = min(10, int(grimace_intensity * 10))

        fatigue = False
        if unresponsive_duration_s > 10.0:
            fatigue = True
            notes.append("Prolonged micro-sleep or heavy fatigue detected.")

        if spasm_detected or tremor_frequency_hz > 6.0:
            notes.append(f"Abnormal motor activity: {tremor_frequency_hz:.1f}Hz rhythmic tremor.")

        if pain_score >= 7:
            notes.append(f"Severe facial pain grimacing scored {pain_score}/10.")
            status = "critical" if unresponsive_duration_s > 5.0 else "elevated_risk"
            rec_action = "Prompt user for pain confirmation and offer caregiver alert."
        elif spasm_detected:
            status = "elevated_risk"
            rec_action = "Initiate abnormal movement verification veto."
        else:
            status = "stable"
            rec_action = "Continue passive ambient monitoring."

        return HealthAssessment(
            pain_level=pain_score,
            fatigue_detected=fatigue,
            abnormal_movement_detected=spasm_detected,
            vital_status=status,
            clinical_notes=notes,
            recommended_action=rec_action,
        )


# ---------------------------------------------------------------------------
# Rehabilitation Agent
# ---------------------------------------------------------------------------


@dataclass(slots=True)
class RehabExerciseStep:
    exercise_id: str
    step_number: int
    instruction: str
    hold_duration_seconds: int
    spoken_feedback: str
    target_body_part: str


class RehabilitationAgent:
    """Guides physical and speech therapy drills turn-by-turn with verbal feedback."""

    EXERCISES: dict[str, list[RehabExerciseStep]] = {
        "neck_mobility": [
            RehabExerciseStep(
                exercise_id="neck_mobility",
                step_number=1,
                instruction="Slowly turn your head to the right side.",
                hold_duration_seconds=3,
                spoken_feedback="Let's move your neck slowly. Turn right... Good.",
                target_body_part="neck",
            ),
            RehabExerciseStep(
                exercise_id="neck_mobility",
                step_number=2,
                instruction="Gently stretch slightly further if comfortable.",
                hold_duration_seconds=3,
                spoken_feedback="Now slightly more... Hold gently... Excellent.",
                target_body_part="neck",
            ),
            RehabExerciseStep(
                exercise_id="neck_mobility",
                step_number=3,
                instruction="Return to center and relax your shoulders.",
                hold_duration_seconds=4,
                spoken_feedback="Slowly back to the center. Relax your shoulders. Great job.",
                target_body_part="neck",
            ),
        ],
        "hand_stretching": [
            RehabExerciseStep(
                exercise_id="hand_stretching",
                step_number=1,
                instruction="Place your hand flat on the armrest and open fingers.",
                hold_duration_seconds=4,
                spoken_feedback="Rest your hand flat on the armrest. Gently spread your fingers.",
                target_body_part="right_hand",
            ),
            RehabExerciseStep(
                exercise_id="hand_stretching",
                step_number=2,
                instruction="Gently tap each fingertip to the thumb if able.",
                hold_duration_seconds=5,
                spoken_feedback="Now try tapping your index finger to your thumb. Very good.",
                target_body_part="right_hand",
            ),
        ],
    }

    def get_exercise_flow(self, exercise_name: str = "neck_mobility") -> list[RehabExerciseStep]:
        return self.EXERCISES.get(exercise_name, self.EXERCISES["neck_mobility"])


# ---------------------------------------------------------------------------
# Emergency Agent
# ---------------------------------------------------------------------------


@dataclass(slots=True)
class EmergencyProtocolResult:
    level: str  # "prompt_user", "call_caregiver", "dispatch_emergency"
    prompt_message: str
    auto_call_caregiver: bool
    priority_alert_sent: bool
    audit_reason: str


class EmergencyAgent:
    """Executes multi-step safety escalation: Detect -> Confirm -> Call -> Alert."""

    def evaluate_emergency(
        self,
        *,
        fall_detected: bool = False,
        no_response_seconds: float = 0.0,
        severe_spasm: bool = False,
        user_confirmed_safe: bool = False,
    ) -> EmergencyProtocolResult:
        if user_confirmed_safe:
            return EmergencyProtocolResult(
                level="standby",
                prompt_message="Emergency dismissed. I am glad you are safe.",
                auto_call_caregiver=False,
                priority_alert_sent=False,
                audit_reason="User confirmed safe via physical confirmation.",
            )

        # Severe Fall or Continuous Unresponsiveness > 8s after fall
        if fall_detected:
            if no_response_seconds >= 8.0:
                return EmergencyProtocolResult(
                    level="dispatch_emergency",
                    prompt_message="Fall detected with no response. Calling caregiver now and dispatching priority alert.",
                    auto_call_caregiver=True,
                    priority_alert_sent=True,
                    audit_reason="Fall detected and user unresponsive after 8 seconds.",
                )
            return EmergencyProtocolResult(
                level="prompt_user",
                prompt_message="I noticed a sudden movement. Are you okay? Blink twice or press anywhere to dismiss.",
                auto_call_caregiver=False,
                priority_alert_sent=False,
                audit_reason="Fall threshold triggered; awaiting user confirmation.",
            )

        if severe_spasm and no_response_seconds > 10.0:
            return EmergencyProtocolResult(
                level="call_caregiver",
                prompt_message="Prolonged spasm detected. Alerting caregiver.",
                auto_call_caregiver=True,
                priority_alert_sent=True,
                audit_reason="Prolonged rhythmic spasm with no responsiveness.",
            )

        return EmergencyProtocolResult(
            level="standby",
            prompt_message="All systems normal.",
            auto_call_caregiver=False,
            priority_alert_sent=False,
            audit_reason="No emergency conditions met.",
        )
