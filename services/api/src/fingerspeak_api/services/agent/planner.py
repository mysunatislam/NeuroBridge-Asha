"""Task Planner for NeuroBridge Asha.

Performs goal decomposition and structured multi-step execution planning
for patient requests, routine management, rehabilitation guidance, and clinical emergency coordination.
"""

from __future__ import annotations

import re
import unicodedata
from collections.abc import Sequence
from dataclasses import asdict, dataclass
from typing import Any

from fingerspeak_api.services.agent.memory import MemoryFact


@dataclass(slots=True)
class PlanStep:
    step_number: int
    tool_name: str
    parameters: dict[str, Any]
    purpose: str
    status: str = "pending"  # "pending", "completed", "failed", "skipped"

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


# Multi-intent decomposition rules across all 7 clinical RAG domains & Action Engine
_PLAN_RULES: list[tuple[re.Pattern[str], str, dict[str, Any], str]] = [
    # Seizure emergency
    (
        re.compile(r"\b(seizure|convuls\w*|jerking fit|খিঁচুনি|কাঁপুনি)\b", re.I),
        "lookup_clinical_guidance",
        {"query": "seizure first aid emergency protocol", "category": "seizure_first_aid"},
        "Retrieve immediate seizure positioning and airway protocols",
    ),
    # Choking / Breathing distress
    (
        re.compile(r"\b(chok\w*|can.?t breathe|cannot breathe|strangl\w*|শ্বাসকষ্ট)\b", re.I),
        "lookup_clinical_guidance",
        {"query": "choking airway obstruction acute distress", "category": "seizure_first_aid"},
        "Retrieve acute choking and breathing distress protocol",
    ),
    # Autonomic Dysreflexia / Spinal Cord Injury
    (
        re.compile(
            r"\b(autonomic dysreflexia|dysreflexia|pounding head|face flushing|sweating above lesion)\b",
            re.I,
        ),
        "lookup_clinical_guidance",
        {
            "query": "spinal cord injury autonomic dysreflexia checklist",
            "category": "spinal_cord_injury",
        },
        "Look up autonomic dysreflexia blood pressure and trigger protocol",
    ),
    # Stroke Rehabilitation / Exercise Coaching
    (
        re.compile(r"\b(rehab\w*|exercise|motor recovery|stroke rehab|স্ট্রেচ|ব্যায়াম)\b", re.I),
        "start_rehabilitation_exercise",
        {"exercise_name": "neck_mobility", "repetitions": 5},
        "Launch interactive step-by-step rehabilitation coaching",
    ),
    # Stroke / Aphasia Clinical RAG
    (
        re.compile(r"\b(stroke|aphasia|trouble speaking|dysarthria|স্ট্রোক)\b", re.I),
        "lookup_clinical_guidance",
        {"query": "stroke motor recovery neuroplasticity", "category": "stroke_rehabilitation"},
        "Review stroke rehabilitation and neuroplasticity motor protocols",
    ),
    # Speech Therapy
    (
        re.compile(r"\b(speech therapy|pronunciation|articulation|phoneme|oral motor)\b", re.I),
        "lookup_clinical_guidance",
        {"query": "speech therapy articulation pacing dysarthria", "category": "speech_therapy"},
        "Retrieve speech therapy and dysarthria pacing guidance",
    ),
    # Autism Support / Sensory
    (
        re.compile(r"\b(autism|sensory overload|overwhelm|meltdown|visual schedule)\b", re.I),
        "lookup_clinical_guidance",
        {"query": "autism sensory regulation visual schedules", "category": "autism_support"},
        "Retrieve autism sensory calming and visual schedule protocol",
    ),
    # ICU Communication
    (
        re.compile(r"\b(icu|intubat\w*|ventilator|suction|trach\w*)\b", re.I),
        "lookup_clinical_guidance",
        {"query": "icu acute communication intubation eye blink", "category": "icu_communication"},
        "Retrieve ICU non-verbal eye-blink communication board",
    ),
    # Physiotherapy & Range of Motion
    (
        re.compile(r"\b(physiotherapy|neck movement|stiff neck|hand stretch|range of motion)\b", re.I),
        "lookup_clinical_guidance",
        {"query": "physiotherapy range of motion spasticity", "category": "physiotherapy"},
        "Retrieve physiotherapy joint mobilization and stretching guidelines",
    ),
    # Caregiver Guidelines
    (
        re.compile(r"\b(caregiver guideline|transfer safety|burnout|body mechanics|lift patient)\b", re.I),
        "lookup_clinical_guidance",
        {"query": "caregiver transfer safety ergonomics offloading", "category": "caregiver_guidelines"},
        "Retrieve clinical caregiver safety and ergonomic transfer guidelines",
    ),
    # User Specific / Digital Twin
    (
        re.compile(r"\b(my profile|digital twin|rahim|who am i|my routine|my doctor)\b", re.I),
        "recall_memory",
        {"query": "digital twin clinical profile preferences", "category": "digital_twin"},
        "Recall personalized User Digital Twin profile and directives",
    ),
    # Symptom Logging (Pain, Tremor, Spasm, Fatigue)
    (
        re.compile(r"\b(pain|hurts|ache|spasm|cramp|tremor|shaking|ব্যথা|কষ্ট)\b", re.I),
        "record_symptom_log",
        {"symptom_type": "pain", "severity": 6, "notes": "Patient reported pain or discomfort."},
        "Record clinical symptom observation in patient history",
    ),
    # Medication Reminder
    (
        re.compile(r"\b(medication|medicine|pill|dose|প্রেসক্রিপশন|ওষুধ)\b", re.I),
        "remind_medication",
        {"medication_name": "Scheduled prescription", "time_label": "routine"},
        "Schedule or verify patient medication adherence reminder",
    ),
    # Device / Hardware / Battery / Camera
    (
        re.compile(r"\b(battery|camera|pi|raspberry|wheelchair|charging|wifi|signal)\b", re.I),
        "check_device_telemetry",
        {},
        "Inspect Raspberry Pi, camera feed, and wheelchair battery status",
    ),
    # Hydration / Water
    (
        re.compile(r"\b(water|drink|hydrat\w*|thirsty|পানি|জল)\b", re.I),
        "manage_care_routine",
        {"action": "check", "category": "hydration"},
        "Check hydration schedule and record routine request",
    ),
    # Repositioning / Pressure Relief
    (
        re.compile(r"\b(reposition|turn over|pressure|bed sore|shift weight)\b", re.I),
        "manage_care_routine",
        {"action": "check", "category": "repositioning"},
        "Check repositioning timer and pressure sore prevention interval",
    ),
    # Wheelchair Display Caption
    (
        re.compile(r"\b(show on screen|display|caption|write to display|screen says?)\b", re.I),
        "send_wheelchair_caption",
        {"text": "Patient requests assistance. Please attend bedside."},
        "Broadcast visual caption on wheelchair companion display",
    ),
    # Direct Voice Call to Caregiver
    (
        re.compile(r"\b(call daughter|call family|phone call|ring caregiver)\b", re.I),
        "call_caregiver",
        {"urgent": True, "reason": "Patient requested direct voice call to caregiver."},
        "Initiate direct telephone/VoIP voice call to caregiver",
    ),
    # Caregiver / Nurse Alert
    (
        re.compile(
            r"\b(?:call|alert|contact|notify|message)(?:\s+(?:the|my|an?))?\s*(?:caregiver|nurse|doctor)\b|\b(?:help(?:\s+me)?|need\s+help|urgent\w*|emergency|সাহায্য|জরুরি)\b",
            re.I,
        ),
        "trigger_caregiver_alert",
        {"severity": "urgent", "message": "Patient has requested bedside assistance."},
        "Dispatch priority alert to authorized caregiver device",
    ),
]


class TaskPlanner:
    """Decomposes patient messages into structured execution plans."""

    def plan(
        self,
        message: str,
        patient_context: dict[str, Any] | None = None,
        recalled_memories: Sequence[MemoryFact] = (),
    ) -> list[PlanStep]:
        normalized = unicodedata.normalize("NFKC", message)
        steps: list[PlanStep] = []
        seen_tools: set[str] = set()

        step_counter = 1

        # Check if recalled memory specifies preferred drinking style
        has_water_query = bool(re.search(r"\b(water|drink|thirsty|পানি|জল)\b", normalized, re.I))
        if has_water_query:
            drinking_pref = next(
                (m.value for m in recalled_memories if m.key == "drinking_preference"), None
            )
            water_step = PlanStep(
                step_number=step_counter,
                tool_name="manage_care_routine",
                parameters={"action": "check", "category": "hydration"},
                purpose=f"Check hydration routine{f' (noted preference: {drinking_pref})' if drinking_pref else ''}",
            )
            steps.append(water_step)
            seen_tools.add("manage_care_routine")
            step_counter += 1

        # Match plan rules
        for pattern, tool_name, params, purpose in _PLAN_RULES:
            if pattern.search(normalized) and tool_name not in seen_tools:
                # Custom caption text extraction if user provided quotes
                if tool_name == "send_wheelchair_caption":
                    quote_match = re.search(r'["\']([^"\']+)["\']', normalized)
                    if quote_match:
                        params = {"text": quote_match.group(1).strip()[:120]}

                # Custom caregiver alert severity detection
                if tool_name == "trigger_caregiver_alert":
                    if any(
                        w in normalized.lower() for w in ("emergency", "danger", "dying", "severe", "জরুরি")
                    ):
                        params = {
                            "severity": "emergency",
                            "message": "EMERGENCY: Patient urgently needs immediate help",
                        }
                    elif any(w in normalized.lower() for w in ("routine", "when you can", "later")):
                        params = {
                            "severity": "routine",
                            "message": "Routine check-in requested by patient",
                        }

                steps.append(
                    PlanStep(
                        step_number=step_counter,
                        tool_name=tool_name,
                        parameters=dict(params),
                        purpose=purpose,
                    )
                )
                seen_tools.add(tool_name)
                step_counter += 1

            if len(steps) >= 5:
                break

        return steps
