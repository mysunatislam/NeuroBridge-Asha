"""Task Planner for NeuroBridge Asha.

Performs goal decomposition and structured multi-step execution planning
for patient requests, routine management, and clinical emergency coordination.
"""

from __future__ import annotations

import json
import re
import unicodedata
from dataclasses import asdict, dataclass, field
from typing import Any, Sequence

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


# Multi-intent decomposition rules
_PLAN_RULES: list[tuple[re.Pattern[str], str, dict[str, Any], str]] = [
    # Seizure emergency
    (
        re.compile(r"\b(seizure|convuls\w*|jerking fit)\b", re.I),
        "lookup_clinical_guidance",
        {"query": "seizure first aid emergency protocol", "category": "seizure_first_aid"},
        "Retrieve immediate seizure positioning and airway protocols",
    ),
    # Choking / Breathing distress
    (
        re.compile(r"\b(chok\w*|can.?t breathe|cannot breathe|strangl\w*)\b", re.I),
        "lookup_clinical_guidance",
        {"query": "choking airway obstruction acute distress", "category": "seizure_first_aid"},
        "Retrieve acute choking and breathing distress protocol",
    ),
    # Autonomic Dysreflexia / Spinal Cord Injury
    (
        re.compile(r"\b(autonomic dysreflexia|dysreflexia|pounding head|face flushing|sweating above lesion)\b", re.I),
        "lookup_clinical_guidance",
        {"query": "spinal cord injury autonomic dysreflexia checklist", "category": "spinal_cord_injury"},
        "Look up autonomic dysreflexia blood pressure and trigger protocol",
    ),
    # ALS / Motor Fatigue / Micro-gestures
    (
        re.compile(r"\b(als|mnd|fatigue|muscle tire|weakness|tremor|dwell)\b", re.I),
        "lookup_clinical_guidance",
        {"query": "ALS MND micro-gesture fatigue management", "category": "als_mnd"},
        "Check fatigue thresholds and assistive gesture calibrations",
    ),
    # Stroke / Aphasia AAC
    (
        re.compile(r"\b(stroke|aphasia|trouble speaking|dysarthria)\b", re.I),
        "lookup_clinical_guidance",
        {"query": "stroke aphasia AAC communication strategies", "category": "stroke_aphasia"},
        "Review visual and phrase-paired aphasia communication strategies",
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
        re.compile(r"\b(water|drink|hydrat\w*|thirsty|গলা শুকিয়ে গেছে)\b", re.I),
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
    # Caregiver / Nurse Alert
    (
        re.compile(
            r"\b(?:call|alert|contact|notify|message)(?:\s+(?:the|my|an?))?\s*(?:caregiver|nurse|doctor)\b|\b(?:help(?:\s+me)?|need\s+help|urgent\w*|emergency)\b",
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
        has_water_query = bool(re.search(r"\b(water|drink|thirsty)\b", normalized, re.I))
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
                    if any(w in normalized.lower() for w in ("emergency", "danger", "dying", "severe")):
                        params = {"severity": "emergency", "message": "EMERGENCY: Patient urgently needs immediate help"}
                    elif any(w in normalized.lower() for w in ("routine", "when you can", "later")):
                        params = {"severity": "routine", "message": "Routine check-in requested by patient"}

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

            if len(steps) >= 4:
                break

        return steps
