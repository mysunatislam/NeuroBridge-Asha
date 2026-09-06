"""Agent runner and tool tests for NeuroBridge Asha."""
from __future__ import annotations

import pytest

from fingerspeak_api.services.agent.agent_runner import AgentRunner, _offline_select_tools
from fingerspeak_api.services.agent.tools import AgentToolRegistry, TOOL_DEFINITIONS
from fingerspeak_api.services.rag.engine import EmbeddedRAGRetriever


@pytest.fixture
def tool_registry() -> AgentToolRegistry:
    return AgentToolRegistry(
        rag_retriever=EmbeddedRAGRetriever(),
        device_telemetry={
            "pi_battery_percent": 88,
            "wheelchair_battery_percent": 72,
            "camera_status": "active",
            "wheelchair_status": "idle",
        },
    )


@pytest.fixture
def offline_runner(tool_registry: AgentToolRegistry) -> AgentRunner:
    return AgentRunner(tool_registry=tool_registry)


# --- Offline semantic planner ---

def test_offline_planner_seizure_intent() -> None:
    selected = _offline_select_tools("My patient is having a convulsion, what should I do?")
    assert len(selected) > 0
    assert selected[0][0] == "lookup_clinical_guidance"
    assert "seizure" in selected[0][1]["query"].lower()


def test_offline_planner_caregiver_alert_intent() -> None:
    selected = _offline_select_tools("Call the caregiver and alert the nurse urgently")
    tool_names = [s[0] for s in selected]
    assert "trigger_caregiver_alert" in tool_names


def test_offline_planner_device_telemetry_intent() -> None:
    selected = _offline_select_tools("Check the raspberry pi battery and camera status")
    assert len(selected) > 0
    assert selected[0][0] == "check_device_telemetry"


def test_offline_planner_water_intent() -> None:
    selected = _offline_select_tools("I am thirsty and need water")
    assert len(selected) > 0
    assert selected[0][0] == "manage_care_routine"
    assert selected[0][1]["category"] == "hydration"


def test_offline_planner_unrecognized_returns_empty() -> None:
    selected = _offline_select_tools("hello")
    assert selected == []


# --- Tool registry tests ---

@pytest.mark.asyncio
async def test_tool_registry_lookup_clinical_guidance(tool_registry: AgentToolRegistry) -> None:
    result = await tool_registry.call("lookup_clinical_guidance", {"query": "seizure first aid"})
    import json
    data = json.loads(result)
    assert data["found"] is True
    assert len(data["results"]) > 0
    assert data["results"][0]["category"] == "seizure_first_aid"
    assert len(tool_registry.executions) == 1
    assert tool_registry.executions[0].success is True


@pytest.mark.asyncio
async def test_tool_registry_check_device_telemetry(tool_registry: AgentToolRegistry) -> None:
    import json
    result = await tool_registry.call("check_device_telemetry", {})
    data = json.loads(result)
    assert data["online"] is True
    assert data["pi_battery_percent"] == 88
    assert data["camera_status"] == "active"


@pytest.mark.asyncio
async def test_tool_registry_caregiver_alert(tool_registry: AgentToolRegistry) -> None:
    import json
    result = await tool_registry.call(
        "trigger_caregiver_alert",
        {"severity": "urgent", "message": "Patient needs immediate assistance"}
    )
    data = json.loads(result)
    assert data["dispatched"] is True
    assert data["severity"] == "urgent"


@pytest.mark.asyncio
async def test_tool_registry_caption(tool_registry: AgentToolRegistry) -> None:
    import json
    result = await tool_registry.call("send_wheelchair_caption", {"text": "Hello!"})
    data = json.loads(result)
    assert data["sent"] is True


@pytest.mark.asyncio
async def test_tool_registry_invalid_tool_is_handled(tool_registry: AgentToolRegistry) -> None:
    import json
    result = await tool_registry.call("nonexistent_tool", {})
    data = json.loads(result)
    assert "error" in data
    assert tool_registry.executions[-1].success is False


# --- Full offline agent runner integration ---

@pytest.mark.asyncio
async def test_offline_runner_seizure_scenario(offline_runner: AgentRunner) -> None:
    output = await offline_runner.run(
        "The patient just had a seizure. What do I do?"
    )
    assert output.mode == "offline-agent"
    assert len(output.reply) > 20
    assert len(output.actions_executed) > 0
    assert any("seizure" in c["title"].lower() for c in output.citations)


@pytest.mark.asyncio
async def test_offline_runner_device_check(offline_runner: AgentRunner) -> None:
    output = await offline_runner.run("Can you check the wheelchair camera and battery?")
    assert output.mode == "offline-agent"
    assert any(ex.tool_name == "check_device_telemetry" for ex in output.actions_executed)
    assert "88" in output.reply or "battery" in output.reply.lower()


@pytest.mark.asyncio
async def test_offline_runner_no_match_returns_fallback(offline_runner: AgentRunner) -> None:
    output = await offline_runner.run("hello how are you")
    assert output.mode == "offline-agent"
    assert len(output.reply) > 10
    assert len(output.quick_actions) > 0


@pytest.mark.asyncio
async def test_agent_output_always_has_quick_actions(offline_runner: AgentRunner) -> None:
    output = await offline_runner.run("I need water")
    assert len(output.quick_actions) > 0
    action_keys = {qa["action_key"] for qa in output.quick_actions}
    assert "request_water" in action_keys or "need_help" in action_keys


def test_tool_definitions_schema_is_well_formed() -> None:
    assert len(TOOL_DEFINITIONS) == 6
    for td in TOOL_DEFINITIONS:
        assert td["type"] == "function"
        assert "name" in td["function"]
        assert "description" in td["function"]
        assert "parameters" in td["function"]
