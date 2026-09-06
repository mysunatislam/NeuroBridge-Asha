"""Agentic reasoning loop for NeuroBridge Asha.

Runs up to N=3 agentic tool calls, supporting:
- OpenAI function calling (Responses API)
- Google Gemini function declarations
- Offline deterministic semantic planner (zero API dependency)
"""

from __future__ import annotations

import json
import re
import unicodedata
from dataclasses import dataclass, field
from typing import Any

import httpx

from fingerspeak_api.services.agent.tools import AgentToolRegistry, TOOL_DEFINITIONS, ToolExecution

MAX_TOOL_ROUNDS = 3

# ---------------------------------------------------------------------------
# Offline Semantic Planner — guaranteed fallback with no external dependencies
# ---------------------------------------------------------------------------

_INTENT_PATTERNS: list[tuple[re.Pattern[str], str, str]] = [
    (re.compile(r"\b(seizure|convuls\w*|choking|can.?t breathe)\b", re.I), "lookup_clinical_guidance", '{"query": "seizure first aid emergency protocol"}'),
    (re.compile(r"\b(als|amyotroph|motor neuron|mnd|fatigue|dwell)\b", re.I), "lookup_clinical_guidance", '{"query": "ALS MND micro-gesture fatigue management"}'),
    (re.compile(r"\b(stroke|aphasia|hemipar)\b", re.I), "lookup_clinical_guidance", '{"query": "stroke aphasia AAC communication strategies"}'),
    (re.compile(r"\b(dysreflexia|tetrapleg|quadriple|spinal cord)\b", re.I), "lookup_clinical_guidance", '{"query": "spinal cord injury autonomic dysreflexia"}'),
    (re.compile(r"\b(water|hydrat|drink|thirsty)\b", re.I), "manage_care_routine", '{"action": "check", "category": "hydration"}'),
    (re.compile(r"\b(reposition|pressure|sore|turn over)\b", re.I), "manage_care_routine", '{"action": "check", "category": "repositioning"}'),
    (re.compile(r"\b(camera|raspberry|pi|battery|wheelchair|charging|wifi)\b", re.I), "check_device_telemetry", '{}'),
    (re.compile(r"\b(caregiver|nurse|call|alert|help me|emergency|urgent)\b", re.I), "trigger_caregiver_alert", '{"severity": "urgent", "message": "Patient has requested caregiver assistance."}'),
    (re.compile(r"\b(display|show|screen|caption)\b", re.I), "send_wheelchair_caption", '{"text": "I need assistance. Please come to me."}'),
]


def _offline_select_tools(message: str) -> list[tuple[str, dict[str, Any]]]:
    normalized = unicodedata.normalize("NFKC", message)
    selected: list[tuple[str, dict[str, Any]]] = []
    seen_tools: set[str] = set()
    for pattern, tool_name, args_json in _INTENT_PATTERNS:
        if pattern.search(normalized) and tool_name not in seen_tools:
            seen_tools.add(tool_name)
            selected.append((tool_name, json.loads(args_json)))
        if len(selected) >= 2:
            break
    return selected


# ---------------------------------------------------------------------------
# Output schema
# ---------------------------------------------------------------------------

@dataclass(slots=True)
class AgentOutput:
    reply: str
    mode: str
    actions_executed: list[ToolExecution] = field(default_factory=list)
    citations: list[dict[str, str]] = field(default_factory=list)
    quick_actions: list[dict[str, str]] = field(default_factory=list)
    urgent: bool = False


# ---------------------------------------------------------------------------
# Agent Runner
# ---------------------------------------------------------------------------

class AgentRunner:
    """Orchestrates multi-step agentic tool calling for a single chat turn."""

    def __init__(
        self,
        *,
        tool_registry: AgentToolRegistry,
        gemini_api_key: str | None = None,
        gemini_model: str = "gemini-2.0-flash",
        openai_api_key: str | None = None,
        openai_model: str = "gpt-4o-mini",
        timeout_seconds: float = 12.0,
        max_output_tokens: int = 500,
        locale: str = "en-US",
    ) -> None:
        self._tools = tool_registry
        self._gemini_key = gemini_api_key
        self._gemini_model = gemini_model
        self._openai_key = openai_api_key
        self._openai_model = openai_model
        self._timeout = timeout_seconds
        self._max_tokens = max_output_tokens
        self._locale = locale

    async def run(self, message: str, patient_context: dict[str, Any] | None = None) -> AgentOutput:
        # 1. Try Gemini agentic loop
        if self._gemini_key:
            try:
                return await self._run_gemini(message, patient_context or {})
            except Exception:
                pass

        # 2. Try OpenAI function-calling loop
        if self._openai_key:
            try:
                return await self._run_openai(message, patient_context or {})
            except Exception:
                pass

        # 3. Offline deterministic planner
        return await self._run_offline(message, patient_context or {})

    # ------------------------------------------------------------------
    # Gemini Agentic Loop
    # ------------------------------------------------------------------

    async def _run_gemini(self, message: str, context: dict[str, Any]) -> AgentOutput:
        system_prompt = self._system_prompt(context)
        user_text = message

        # Convert OpenAI-style tool definitions to Gemini function declarations
        function_declarations = [
            {
                "name": td["function"]["name"],
                "description": td["function"]["description"],
                "parameters": td["function"]["parameters"],
            }
            for td in TOOL_DEFINITIONS
        ]

        contents: list[dict[str, Any]] = [{"role": "user", "parts": [{"text": user_text}]}]
        tool_rounds = 0

        async with httpx.AsyncClient(timeout=httpx.Timeout(self._timeout)) as client:
            while tool_rounds < MAX_TOOL_ROUNDS:
                payload: dict[str, Any] = {
                    "system_instruction": {"parts": [{"text": system_prompt}]},
                    "contents": contents,
                    "tools": [{"function_declarations": function_declarations}],
                    "generationConfig": {
                        "temperature": 0.4,
                        "maxOutputTokens": self._max_tokens,
                    },
                }
                url = (
                    f"https://generativelanguage.googleapis.com/v1beta/models/"
                    f"{self._gemini_model}:generateContent?key={self._gemini_key}"
                )
                resp = await client.post(url, headers={"Content-Type": "application/json"}, json=payload)
                resp.raise_for_status()
                data = resp.json()

                candidates = data.get("candidates") or []
                if not candidates:
                    raise RuntimeError("Gemini returned no candidates")

                content_block = candidates[0].get("content", {})
                parts = content_block.get("parts", [])

                # Check for function calls
                function_calls = [p for p in parts if "functionCall" in p]
                if not function_calls:
                    # Extract text reply
                    text_parts = [p.get("text", "") for p in parts if "text" in p]
                    reply = " ".join(text_parts).strip()
                    if not reply:
                        raise RuntimeError("Gemini returned no text content")
                    return self._build_output(reply, "gemini-agent")

                # Execute function calls
                function_responses = []
                for fc_part in function_calls:
                    fc = fc_part["functionCall"]
                    tool_name = fc["name"]
                    tool_args = fc.get("args", {})
                    result_json = await self._tools.call(tool_name, tool_args)
                    function_responses.append({
                        "functionResponse": {
                            "name": tool_name,
                            "response": json.loads(result_json),
                        }
                    })

                # Extend conversation history
                contents.append({"role": "model", "parts": parts})
                contents.append({"role": "user", "parts": function_responses})
                tool_rounds += 1

        raise RuntimeError("Gemini agent loop exceeded maximum tool rounds without text reply")

    # ------------------------------------------------------------------
    # OpenAI Agentic Loop
    # ------------------------------------------------------------------

    async def _run_openai(self, message: str, context: dict[str, Any]) -> AgentOutput:
        system_prompt = self._system_prompt(context)
        messages: list[dict[str, Any]] = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": message},
        ]
        tool_rounds = 0

        async with httpx.AsyncClient(timeout=httpx.Timeout(self._timeout)) as client:
            while tool_rounds < MAX_TOOL_ROUNDS:
                payload = {
                    "model": self._openai_model,
                    "messages": messages,
                    "tools": TOOL_DEFINITIONS,
                    "tool_choice": "auto",
                    "max_tokens": self._max_tokens,
                    "temperature": 0.4,
                }
                resp = await client.post(
                    "https://api.openai.com/v1/chat/completions",
                    headers={
                        "Authorization": f"Bearer {self._openai_key}",
                        "Content-Type": "application/json",
                    },
                    json=payload,
                )
                resp.raise_for_status()
                data = resp.json()

                choice = data["choices"][0]
                msg = choice["message"]

                if not msg.get("tool_calls"):
                    reply = msg.get("content", "").strip()
                    if not reply:
                        raise RuntimeError("OpenAI returned no content")
                    return self._build_output(reply, "openai-agent")

                # Execute tool calls
                messages.append(msg)
                for tc in msg["tool_calls"]:
                    tool_name = tc["function"]["name"]
                    tool_args = json.loads(tc["function"]["arguments"])
                    result_json = await self._tools.call(tool_name, tool_args)
                    messages.append({
                        "role": "tool",
                        "tool_call_id": tc["id"],
                        "content": result_json,
                    })
                tool_rounds += 1

        raise RuntimeError("OpenAI agent loop exceeded maximum tool rounds")

    # ------------------------------------------------------------------
    # Offline Deterministic Semantic Planner
    # ------------------------------------------------------------------

    async def _run_offline(self, message: str, context: dict[str, Any]) -> AgentOutput:
        tool_calls = _offline_select_tools(message)

        tool_summaries: list[str] = []
        rag_results: list[dict[str, Any]] = []

        for tool_name, tool_args in tool_calls:
            result_json = await self._tools.call(tool_name, tool_args)
            result = json.loads(result_json)

            if tool_name == "lookup_clinical_guidance" and result.get("found"):
                for doc in result.get("results", [])[:2]:
                    tool_summaries.append(f"• {doc['title']}: {doc['snippet'][:180]}")
                    rag_results.append({"title": doc["title"], "source_id": doc["source_id"]})
            else:
                summary = result.get("summary", "")
                if summary:
                    tool_summaries.append(f"• {summary}")

        # Build offline grounded reply
        if tool_summaries:
            body = "\n".join(tool_summaries)
            reply = (
                f"Here's what I found to help you:\n{body}\n\n"
                "I'm in offline mode — I can still access my built-in clinical guidance. "
                "Let me know how I can support you further."
            )
        else:
            preferred_name = context.get("preferred_name", "")
            greeting = f"I'm here with you{', ' + preferred_name if preferred_name else ''}. "
            reply = (
                f"{greeting}I'm in offline mode right now but I'm still listening. "
                "You can write a short message, use gesture phrases, or contact your caregiver directly."
            )

        output = self._build_output(reply, "offline-agent")
        output.citations = rag_results
        return output

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _system_prompt(self, context: dict[str, Any]) -> str:
        name_clause = f" The patient's name is {context['preferred_name']}." if context.get("preferred_name") else ""
        care_mode = context.get("care_mode", "continuous")
        locale = context.get("locale", self._locale)
        return (
            f"You are Asha, a calm, compassionate, and effective assistive AI companion for patients "
            f"with motor disabilities.{name_clause} Care mode: {care_mode}. Reply locale: {locale}.\n\n"
            "Your goals:\n"
            "1. Provide accurate, grounded, reassuring responses based on tool results.\n"
            "2. Use tools proactively when clinical guidance, device status, or caregiver actions are needed.\n"
            "3. Keep spoken responses concise (2-3 sentences), warm, and actionable.\n"
            "4. Never diagnose, prescribe, or claim you placed an emergency call.\n"
            "5. If immediate danger is described, advise using the app's confirmed caregiver emergency pathway.\n"
            "6. After using tools, weave their results naturally into a single, cohesive, spoken response.\n"
            "7. When you take an action (like alerting a caregiver), acknowledge it clearly and reassuringly."
        )

    def _build_output(self, reply: str, mode: str) -> AgentOutput:
        executions = self._tools.executions
        citations: list[dict[str, str]] = []
        quick_actions: list[dict[str, str]] = []

        for ex in executions:
            if ex.tool_name == "lookup_clinical_guidance" and ex.success:
                for doc in ex.result.get("results", []):
                    citations.append({"title": doc["title"], "source_id": doc["source_id"]})

        # Suggest contextual quick actions based on what was executed
        tool_names = {ex.tool_name for ex in executions}
        if "trigger_caregiver_alert" not in tool_names:
            quick_actions.append({"label": "Alert Caregiver", "action_key": "alert_caregiver", "payload": "urgent"})
        if "check_device_telemetry" not in tool_names:
            quick_actions.append({"label": "Check Device", "action_key": "check_device", "payload": ""})
        quick_actions.append({"label": "I need water", "action_key": "request_water", "payload": "hydration"})
        quick_actions.append({"label": "I need help", "action_key": "need_help", "payload": "urgent"})

        return AgentOutput(
            reply=reply[:4000],
            mode=mode,
            actions_executed=executions,
            citations=citations,
            quick_actions=quick_actions[:6],
            urgent=False,
        )
