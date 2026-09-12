"""Autonomous Agentic Cognitive Loop for NeuroBridge Asha.

Implements the closed-loop PEEC (Plan, Execute, Evaluate, Correct) architecture:
1. Plan: Goal decomposition and multi-step tool sequence generation.
2. Execute: Orchestrated tool execution with dependency resolution.
3. Evaluate: 4-point verification (clinical safety, goal fulfillment, RAG grounding, voice tone).
4. Correct: Autonomous reflection and self-correction if verification fails.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from typing import Any

import httpx

from fingerspeak_api.services.agent.memory import PatientMemoryEngine
from fingerspeak_api.services.agent.planner import PlanStep, TaskPlanner
from fingerspeak_api.services.agent.tools import (
    TOOL_DEFINITIONS,
    AgentToolRegistry,
    ToolExecution,
)
from fingerspeak_api.services.agent.verifier import VerificationEngine

MAX_TOOL_ROUNDS = 3
MAX_CORRECTION_ROUNDS = 2


def _offline_select_tools(message: str) -> list[tuple[str, dict[str, Any]]]:
    """Backward compatibility helper for offline tool selection."""
    planner = TaskPlanner()
    steps = planner.plan(message)
    return [(s.tool_name, s.parameters) for s in steps]


# ---------------------------------------------------------------------------
# Output Schema
# ---------------------------------------------------------------------------


@dataclass(slots=True)
class AgentOutput:
    reply: str
    mode: str
    actions_executed: list[ToolExecution] = field(default_factory=list)
    citations: list[dict[str, str]] = field(default_factory=list)
    quick_actions: list[dict[str, str]] = field(default_factory=list)
    plan: list[dict[str, Any]] = field(default_factory=list)
    verification: dict[str, Any] | None = None
    memory_recalled: list[dict[str, Any]] = field(default_factory=list)
    urgent: bool = False


# ---------------------------------------------------------------------------
# Agent Runner with Closed-Loop PEEC
# ---------------------------------------------------------------------------


class AgentRunner:
    """Orchestrates multi-step planning, tool calling, evaluation, and self-correction."""

    def __init__(
        self,
        *,
        tool_registry: AgentToolRegistry,
        memory_engine: PatientMemoryEngine | None = None,
        task_planner: TaskPlanner | None = None,
        verification_engine: VerificationEngine | None = None,
        gemini_api_key: str | None = None,
        gemini_model: str = "gemini-flash-latest",
        openai_api_key: str | None = None,
        openai_model: str = "gpt-4o-mini",
        openai_base_url: str | None = None,
        llm_provider: str = "auto",
        timeout_seconds: float = 12.0,
        max_output_tokens: int = 500,
        locale: str = "en-US",
    ) -> None:
        self._tools = tool_registry
        self._memory = memory_engine or PatientMemoryEngine()
        self._planner = task_planner or TaskPlanner()
        self._verifier = verification_engine or VerificationEngine()
        self._gemini_key = gemini_api_key
        self._gemini_model = gemini_model
        self._openai_key = openai_api_key
        self._openai_model = openai_model
        self._openai_base_url = openai_base_url
        self._llm_provider = llm_provider
        self._timeout = timeout_seconds
        self._max_tokens = max_output_tokens
        self._locale = locale

    async def run(self, message: str, patient_context: dict[str, Any] | None = None) -> AgentOutput:
        context = dict(patient_context or {})
        profile_id = str(context.get("profile_id") or "default_patient")

        # -------------------------------------------------------------
        # Phase 1: Context & Memory Recall
        # -------------------------------------------------------------
        self._memory.seed_initial_profile(
            profile_id=profile_id,
            preferred_name=context.get("preferred_name"),
            care_mode=context.get("care_mode", "continuous"),
            locale=context.get("locale", self._locale),
        )
        recalled_memories = self._memory.recall(message, profile_id=profile_id, top_k=3)
        context["recalled_memories"] = [m.to_dict() for m in recalled_memories]

        # -------------------------------------------------------------
        # Phase 2: Goal Decomposition & Planning
        # -------------------------------------------------------------
        plan_steps = self._planner.plan(
            message=message,
            patient_context=context,
            recalled_memories=recalled_memories,
        )

        # -------------------------------------------------------------
        # Phase 3: Execution (Tool Orchestration)
        # -------------------------------------------------------------
        raw_output: AgentOutput | None = None

        if self._llm_provider == "offline":
            raw_output = await self._run_offline(message, context, plan_steps)
        elif self._gemini_key and self._llm_provider in ("auto", "gemini"):
            try:
                raw_output = await self._run_gemini(message, context, plan_steps)
            except Exception:
                raw_output = None

        if (
            raw_output is None
            and (self._openai_key or self._openai_base_url)
            and self._llm_provider in ("auto", "openai", "ollama")
        ):
            try:
                raw_output = await self._run_openai(message, context, plan_steps)
            except Exception:
                raw_output = None

        if raw_output is None:
            raw_output = await self._run_offline(message, context, plan_steps)

        # -------------------------------------------------------------
        # Phase 4: Evaluation & Closed-Loop Verification
        # -------------------------------------------------------------
        rag_snippets = [
            doc["snippet"]
            for ex in self._tools.executions
            if ex.tool_name == "lookup_clinical_guidance" and ex.success
            for doc in ex.result.get("results", [])
            if "snippet" in doc
        ]

        verification = self._verifier.evaluate(
            user_message=message,
            draft_reply=raw_output.reply,
            actions_executed=self._tools.executions,
            rag_snippets=rag_snippets,
        )

        # -------------------------------------------------------------
        # Phase 5: Autonomous Self-Correction
        # -------------------------------------------------------------
        corrected_reply = raw_output.reply
        if not verification.is_verified:
            # Step 5a: Execute missing required actions
            if verification.missing_actions:
                for missing_tool in verification.missing_actions:
                    if missing_tool == "trigger_caregiver_alert":
                        await self._tools.call(
                            "trigger_caregiver_alert",
                            {
                                "severity": "urgent",
                                "message": f"Assistance required: {message[:90]}",
                            },
                        )
                    elif missing_tool == "manage_care_routine":
                        await self._tools.call(
                            "manage_care_routine",
                            {"action": "check", "category": "hydration"},
                        )
                    elif missing_tool == "send_wheelchair_caption":
                        await self._tools.call(
                            "send_wheelchair_caption",
                            {"text": message[:120]},
                        )

            # Step 5b: Correct safety violations
            if not verification.safety_passed:
                corrected_reply = (
                    "I am here to assist and support you, but I cannot provide medical diagnoses or prescriptions. "
                    "I have notified your caregiver and logged your routine status. Please consult your physician for clinical diagnosis."
                )

            # Step 5c: Re-evaluate after correction
            verification = self._verifier.evaluate(
                user_message=message,
                draft_reply=corrected_reply,
                actions_executed=self._tools.executions,
                rag_snippets=rag_snippets,
            )

        # -------------------------------------------------------------
        # Phase 6: Memory Recording
        # -------------------------------------------------------------
        self._record_insights_to_memory(message, profile_id)

        # -------------------------------------------------------------
        # Phase 7: Final Synthesis
        # -------------------------------------------------------------
        final_output = self._build_output(corrected_reply, raw_output.mode)
        final_output.plan = [step.to_dict() for step in plan_steps]
        final_output.verification = verification.to_dict()
        final_output.memory_recalled = [
            {"category": m.category, "key": m.key, "value": m.value} for m in recalled_memories
        ]
        return final_output

    # ------------------------------------------------------------------
    # Gemini Agentic Loop
    # ------------------------------------------------------------------

    async def _run_gemini(
        self, message: str, context: dict[str, Any], plan: list[PlanStep]
    ) -> AgentOutput:
        system_prompt = self._system_prompt(context, plan)
        user_text = message

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
                        "temperature": 0.3,
                        "maxOutputTokens": self._max_tokens,
                    },
                }
                url = (
                    f"https://generativelanguage.googleapis.com/v1beta/models/"
                    f"{self._gemini_model}:generateContent?key={self._gemini_key}"
                )
                resp = await client.post(
                    url, headers={"Content-Type": "application/json"}, json=payload
                )
                resp.raise_for_status()
                data = resp.json()

                candidates = data.get("candidates") or []
                if not candidates:
                    raise RuntimeError("Gemini returned no candidates")

                content_block = candidates[0].get("content", {})
                parts = content_block.get("parts", [])

                function_calls = [p for p in parts if "functionCall" in p]
                if not function_calls:
                    text_parts = [p.get("text", "") for p in parts if "text" in p]
                    reply = " ".join(text_parts).strip()
                    if not reply:
                        raise RuntimeError("Gemini returned no text content")
                    return self._build_output(reply, "gemini-agent")

                function_responses = []
                for fc_part in function_calls:
                    fc = fc_part["functionCall"]
                    tool_name = fc["name"]
                    tool_args = fc.get("args", {})
                    result_json = await self._tools.call(tool_name, tool_args)
                    function_responses.append(
                        {
                            "functionResponse": {
                                "name": tool_name,
                                "response": json.loads(result_json),
                            }
                        }
                    )

                contents.append({"role": "model", "parts": parts})
                contents.append({"role": "user", "parts": function_responses})
                tool_rounds += 1

        raise RuntimeError("Gemini agent loop exceeded maximum tool rounds without text reply")

    # ------------------------------------------------------------------
    # OpenAI Agentic Loop
    # ------------------------------------------------------------------

    async def _run_openai(
        self, message: str, context: dict[str, Any], plan: list[PlanStep]
    ) -> AgentOutput:
        system_prompt = self._system_prompt(context, plan)
        messages: list[dict[str, Any]] = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": message},
        ]
        tool_rounds = 0

        base_url = (self._openai_base_url or "https://api.openai.com/v1").rstrip("/")
        endpoint = (
            base_url if base_url.endswith("/chat/completions") else f"{base_url}/chat/completions"
        )
        headers = {"Content-Type": "application/json"}
        if self._openai_key:
            headers["Authorization"] = f"Bearer {self._openai_key}"

        async with httpx.AsyncClient(timeout=httpx.Timeout(self._timeout)) as client:
            while tool_rounds < MAX_TOOL_ROUNDS:
                payload = {
                    "model": self._openai_model,
                    "messages": messages,
                    "tools": TOOL_DEFINITIONS,
                    "tool_choice": "auto",
                    "max_tokens": self._max_tokens,
                    "temperature": 0.3,
                }
                resp = await client.post(
                    endpoint,
                    headers=headers,
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

                messages.append(msg)
                for tc in msg["tool_calls"]:
                    tool_name = tc["function"]["name"]
                    tool_args = json.loads(tc["function"]["arguments"])
                    result_json = await self._tools.call(tool_name, tool_args)
                    messages.append(
                        {
                            "role": "tool",
                            "tool_call_id": tc["id"],
                            "content": result_json,
                        }
                    )
                tool_rounds += 1

        raise RuntimeError("OpenAI agent loop exceeded maximum tool rounds")

    # ------------------------------------------------------------------
    # Offline Deterministic Semantic Planner
    # ------------------------------------------------------------------

    async def _run_offline(
        self, message: str, context: dict[str, Any], plan: list[PlanStep]
    ) -> AgentOutput:
        tool_summaries: list[str] = []
        rag_results: list[dict[str, Any]] = []

        # Execute plan steps
        for step in plan:
            result_json = await self._tools.call(step.tool_name, step.parameters)
            result = json.loads(result_json)
            step.status = "completed" if "error" not in result else "failed"

            if step.tool_name == "lookup_clinical_guidance" and result.get("found"):
                for doc in result.get("results", [])[:2]:
                    tool_summaries.append(f"• {doc['title']}: {doc['snippet'][:180]}")
                    rag_results.append({"title": doc["title"], "source_id": doc["source_id"]})
            else:
                summary = result.get("summary", "")
                if summary:
                    tool_summaries.append(f"• {summary}")

        # Grounded reply synthesis
        preferred_name = context.get("preferred_name", "")
        greeting = f"I'm here with you{', ' + preferred_name if preferred_name else ''}. "

        if tool_summaries:
            body = "\n".join(tool_summaries)
            reply = (
                f"{greeting}Here is the verified guidance:\n{body}\n\n"
                "I have coordinated the requested actions and will remain active bedside."
            )
        else:
            reply = (
                f"{greeting}I am actively monitoring and listening. "
                "You can use gesture phrases, update your wheelchair display, or request water or caregiver help anytime."
            )

        output = self._build_output(reply, "offline-agent")
        output.citations = rag_results
        return output

    # ------------------------------------------------------------------
    # Internal Helpers
    # ------------------------------------------------------------------

    def _system_prompt(self, context: dict[str, Any], plan: list[PlanStep]) -> str:
        name_clause = (
            f" Patient name: {context['preferred_name']}." if context.get("preferred_name") else ""
        )
        care_mode = context.get("care_mode", "continuous")
        locale = context.get("locale", self._locale)

        plan_summary = ""
        if plan:
            steps_str = "; ".join(f"{s.step_number}. {s.purpose} ({s.tool_name})" for s in plan)
            plan_summary = f"\nAutonomous Execution Plan:\n{steps_str}\n"

        memory_summary = ""
        recalled = context.get("recalled_memories") or []
        if recalled:
            mem_str = "; ".join(f"{m['key']}: {m['value']}" for m in recalled)
            memory_summary = f"\nPatient Recalled Context:\n{mem_str}\n"

        return (
            f"You are Asha, a calm, compassionate, and clinically grounded assistive AI companion for patients "
            f"with motor disabilities.{name_clause} Care mode: {care_mode}. Locale: {locale}.{plan_summary}{memory_summary}\n\n"
            "Cognitive Principles:\n"
            "1. Plan and execute tools autonomously to fulfill patient needs.\n"
            "2. Ground every clinical claim strictly in tool retrieval results.\n"
            "3. Keep spoken replies concise (2-3 warm sentences) suitable for Samantha TTS playback.\n"
            "4. NEVER diagnose diseases or prescribe medication.\n"
            "5. If emergency distress is present, invoke emergency protocol and alert caregivers."
        )

    def _record_insights_to_memory(self, message: str, profile_id: str) -> None:
        """Detect and store persistent patient preferences from natural conversation."""
        normalized = message.lower()
        # Name preference
        name_match = re.search(r"\b(?:my name is|call me|i am|i'm) ([a-z]{2,20})\b", normalized)
        if name_match:
            name = name_match.group(1).capitalize()
            if name not in ("Asha", "Sick", "Tired", "Fine", "Good", "Here"):
                self._memory.store(profile_id, "preference", "preferred_name", name)

        # Drinking style
        if "straw" in normalized:
            self._memory.store(profile_id, "preference", "drinking_preference", "water with straw")
        elif "warm water" in normalized or "hot water" in normalized:
            self._memory.store(profile_id, "preference", "drinking_preference", "warm water")

    def _build_output(self, reply: str, mode: str) -> AgentOutput:
        executions = self._tools.executions
        citations: list[dict[str, str]] = []
        quick_actions: list[dict[str, str]] = []

        for ex in executions:
            if ex.tool_name == "lookup_clinical_guidance" and ex.success:
                for doc in ex.result.get("results", []):
                    citations.append({"title": doc["title"], "source_id": doc["source_id"]})

        tool_names = {ex.tool_name for ex in executions}
        if "trigger_caregiver_alert" not in tool_names:
            quick_actions.append(
                {"label": "Alert Caregiver", "action_key": "alert_caregiver", "payload": "urgent"}
            )
        if "check_device_telemetry" not in tool_names:
            quick_actions.append(
                {"label": "Check Device", "action_key": "check_device", "payload": ""}
            )
        quick_actions.append(
            {"label": "I need water", "action_key": "request_water", "payload": "hydration"}
        )
        quick_actions.append(
            {"label": "I need help", "action_key": "need_help", "payload": "urgent"}
        )

        return AgentOutput(
            reply=reply[:4000],
            mode=mode,
            actions_executed=executions,
            citations=citations,
            quick_actions=quick_actions[:6],
            urgent=False,
        )
