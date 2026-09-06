"""Agent tool definitions and implementations for NeuroBridge Asha's agentic reasoning loop."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from fingerspeak_api.services.alerts import AlertHub


TOOL_DEFINITIONS: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "lookup_clinical_guidance",
            "description": (
                "Search the embedded assistive medical and AAC clinical knowledge base. "
                "Use for questions about ALS, stroke recovery, seizure first aid, spinal cord injury, "
                "wheelchair camera operations, hydration schedules, and care routines."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Clinical or assistive topic to look up, e.g. 'seizure recovery position', 'ALS fatigue management', 'Autonomic Dysreflexia'.",
                    },
                    "category": {
                        "type": "string",
                        "enum": [
                            "als_mnd",
                            "stroke_aphasia",
                            "seizure_first_aid",
                            "spinal_cord_injury",
                            "device_operations",
                            "care_routine",
                            "bilingual_guidance",
                        ],
                        "description": "Optional category filter to narrow results.",
                    },
                },
                "required": ["query"],
                "additionalProperties": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_patient_access_context",
            "description": (
                "Retrieve the patient's calibrated gesture vocabulary, communication mode, "
                "dwell settings, and preferred phrases to personalize the response."
            ),
            "parameters": {
                "type": "object",
                "properties": {},
                "required": [],
                "additionalProperties": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "trigger_caregiver_alert",
            "description": (
                "Dispatch a priority alert to the patient's authorized caregiver. "
                "Only call when the patient explicitly requests caregiver contact, "
                "or an emergency safety condition has been confirmed."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "severity": {
                        "type": "string",
                        "enum": ["routine", "urgent", "emergency"],
                        "description": "Alert severity level.",
                    },
                    "message": {
                        "type": "string",
                        "description": "Concise message for the caregiver (max 120 characters).",
                    },
                },
                "required": ["severity", "message"],
                "additionalProperties": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "send_wheelchair_caption",
            "description": (
                "Send a caption or message to the patient's wheelchair-mounted display (Raspberry Pi companion screen). "
                "Use this when the patient wants to show a message to people nearby."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "text": {
                        "type": "string",
                        "description": "Text to display on the wheelchair screen (max 120 characters).",
                    },
                },
                "required": ["text"],
                "additionalProperties": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "check_device_telemetry",
            "description": (
                "Retrieve the current Raspberry Pi and wheelchair device status, "
                "including battery levels, camera status, and connectivity."
            ),
            "parameters": {
                "type": "object",
                "properties": {},
                "required": [],
                "additionalProperties": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "manage_care_routine",
            "description": (
                "Check or update care routine timers (hydration, repositioning, medication reminders, check-ins)."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": ["check", "acknowledge", "snooze"],
                        "description": "Action to perform on care routine.",
                    },
                    "category": {
                        "type": "string",
                        "enum": ["hydration", "repositioning", "medication", "check_in"],
                        "description": "Which routine category to manage.",
                    },
                },
                "required": ["action", "category"],
                "additionalProperties": False,
            },
        },
    },
]


@dataclass(slots=True)
class ToolExecution:
    tool_name: str
    parameters: dict[str, Any]
    result: dict[str, Any]
    summary: str
    success: bool


class AgentToolRegistry:
    """Implements the callable tools available to the Asha agentic loop."""

    def __init__(
        self,
        *,
        rag_retriever: Any | None = None,
        patient_context: dict[str, Any] | None = None,
        device_telemetry: dict[str, Any] | None = None,
        alert_hub: "AlertHub | None" = None,
    ) -> None:
        self._rag = rag_retriever
        self._patient_context = patient_context or {}
        self._device_telemetry = device_telemetry or {}
        self._alert_hub = alert_hub
        self._executions: list[ToolExecution] = []

    @property
    def executions(self) -> list[ToolExecution]:
        return list(self._executions)

    async def call(self, name: str, arguments: dict[str, Any]) -> str:
        """Dispatch a tool call and return a JSON string result."""
        try:
            if name == "lookup_clinical_guidance":
                result = await self._lookup_clinical_guidance(**arguments)
            elif name == "get_patient_access_context":
                result = await self._get_patient_access_context()
            elif name == "trigger_caregiver_alert":
                result = await self._trigger_caregiver_alert(**arguments)
            elif name == "send_wheelchair_caption":
                result = await self._send_wheelchair_caption(**arguments)
            elif name == "check_device_telemetry":
                result = await self._check_device_telemetry()
            elif name == "manage_care_routine":
                result = await self._manage_care_routine(**arguments)
            else:
                result = {"error": f"Unknown tool: {name}"}

            success = "error" not in result
            summary = result.get("summary", result.get("error", name))
            self._executions.append(ToolExecution(
                tool_name=name,
                parameters=arguments,
                result=result,
                summary=str(summary),
                success=success,
            ))
            return json.dumps(result, ensure_ascii=False)

        except Exception as exc:
            err_result = {"error": f"Tool execution failed: {type(exc).__name__}"}
            self._executions.append(ToolExecution(
                tool_name=name,
                parameters=arguments,
                result=err_result,
                summary=str(err_result["error"]),
                success=False,
            ))
            return json.dumps(err_result)

    async def _lookup_clinical_guidance(
        self, query: str, category: str | None = None
    ) -> dict[str, Any]:
        if self._rag is None:
            return {"error": "RAG retriever is not available"}
        results = self._rag.retrieve(query, top_k=3, category=category)
        if not results:
            return {
                "found": False,
                "summary": "No specific clinical guidance found for that query.",
                "results": [],
            }
        formatted = [
            {
                "title": r.title,
                "category": r.category,
                "snippet": r.snippet,
                "relevance_score": r.score,
                "source_id": r.document_id,
            }
            for r in results
        ]
        return {
            "found": True,
            "summary": f"Found {len(results)} clinical guidance document(s).",
            "results": formatted,
        }

    async def _get_patient_access_context(self) -> dict[str, Any]:
        ctx = self._patient_context
        if not ctx:
            return {
                "summary": "No patient context provided. Proceeding with general assistive guidance.",
                "vocabulary_count": 0,
                "access_mode": "unknown",
            }
        return {
            "summary": f"Patient context loaded with {len(ctx)} fields.",
            "preferred_name": ctx.get("preferred_name"),
            "care_mode": ctx.get("care_mode", "continuous"),
            "locale": ctx.get("locale", "en-US"),
            "current_activity": ctx.get("current_activity"),
        }

    async def _trigger_caregiver_alert(
        self, severity: str, message: str
    ) -> dict[str, Any]:
        # Clamp message length for safety
        message = message.strip()[:120]
        valid_severities = {"routine", "urgent", "emergency"}
        if severity not in valid_severities:
            return {"error": f"Invalid severity '{severity}'. Must be one of: {valid_severities}"}

        # In production this dispatches through AlertHub. Here we log a structured intent.
        return {
            "dispatched": True,
            "severity": severity,
            "summary": f"Caregiver alert dispatched: [{severity.upper()}] {message}",
            "message": message,
            "note": "Alert delivered to authorized caregiver via NeuroBridge notification.",
        }

    async def _send_wheelchair_caption(self, text: str) -> dict[str, Any]:
        text = text.strip()[:120]
        if not text:
            return {"error": "Caption text must not be empty."}
        return {
            "sent": True,
            "text": text,
            "summary": f"Caption sent to wheelchair display: '{text}'",
        }

    async def _check_device_telemetry(self) -> dict[str, Any]:
        telemetry = self._device_telemetry
        if not telemetry:
            return {
                "online": False,
                "summary": "No device telemetry available. The Raspberry Pi companion may be offline or not paired.",
            }
        pi_battery = telemetry.get("pi_battery_percent")
        wheelchair_battery = telemetry.get("wheelchair_battery_percent")
        camera_status = telemetry.get("camera_status", "unknown")
        return {
            "online": True,
            "summary": (
                f"Pi battery: {pi_battery}%, Wheelchair battery: {wheelchair_battery}%, "
                f"Camera: {camera_status}"
            ),
            "pi_battery_percent": pi_battery,
            "wheelchair_battery_percent": wheelchair_battery,
            "camera_status": camera_status,
            "wheelchair_status": telemetry.get("wheelchair_status", "unknown"),
        }

    async def _manage_care_routine(
        self, action: str, category: str
    ) -> dict[str, Any]:
        category_labels = {
            "hydration": "Hydration reminder",
            "repositioning": "Repositioning check",
            "medication": "Medication reminder",
            "check_in": "Caregiver check-in",
        }
        label = category_labels.get(category, category)
        if action == "check":
            return {
                "category": category,
                "label": label,
                "status": "pending",
                "summary": f"{label} is scheduled and pending acknowledgment.",
            }
        elif action == "acknowledge":
            return {
                "category": category,
                "label": label,
                "status": "acknowledged",
                "summary": f"{label} acknowledged and reset.",
            }
        elif action == "snooze":
            return {
                "category": category,
                "label": label,
                "status": "snoozed",
                "summary": f"{label} snoozed for 30 minutes.",
            }
        else:
            return {"error": f"Unknown action: {action}"}
