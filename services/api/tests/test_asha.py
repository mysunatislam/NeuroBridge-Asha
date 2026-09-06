from __future__ import annotations

import httpx

from fingerspeak_api.schemas import AshaChatRequest, AshaCitation
from fingerspeak_api.services.asha import AshaService, ProviderReply, RetrievalPlan
from tests.helpers import OWNER_HEADERS


class FakeProvider:
    def __init__(self, *, fail: bool = False) -> None:
        self.calls = 0
        self.fail = fail

    async def complete(self, request: AshaChatRequest, retrieval: RetrievalPlan) -> ProviderReply:
        self.calls += 1
        if self.fail:
            raise RuntimeError("provider unavailable")
        assert request.message == "Stay with me"
        assert retrieval.tools == ()
        return ProviderReply(
            reply="I’m right here with you.",
            previous_response_id="resp_fake_1",
            citations=(AshaCitation(title="Care guide", source_id="file_fake"),),
        )


async def test_asha_api_works_without_provider_configuration(client: httpx.AsyncClient) -> None:
    response = await client.post(
        "/v1/asha/chat",
        headers=OWNER_HEADERS,
        json={"message": "Hello Asha", "locale": "en-US"},
    )

    assert response.status_code == 200, response.text
    # With agentic runner always wired, expect offline-agent or fallback mode
    assert response.json()["mode"] in ("fallback", "offline-agent")
    assert response.json()["urgent"] is False
    assert isinstance(response.json()["citations"], list)


async def test_asha_uses_injected_provider_without_a_live_call() -> None:
    provider = FakeProvider()
    service = AshaService(provider)

    response = await service.chat(AshaChatRequest(message="Stay with me"))

    assert provider.calls == 1
    assert response.mode == "llm"
    assert response.previous_response_id == "resp_fake_1"
    assert response.citations[0].title == "Care guide"


async def test_urgent_message_preempts_provider() -> None:
    provider = FakeProvider()
    service = AshaService(provider)

    response = await service.chat(AshaChatRequest(message="I cannot breathe"))

    assert response.mode == "safety"
    assert response.urgent is True
    assert provider.calls == 0


async def test_provider_failure_returns_fallback_without_exposing_details() -> None:
    service = AshaService(FakeProvider(fail=True))

    response = await service.chat(AshaChatRequest(message="Stay with me"))

    assert response.mode == "fallback"
    assert "provider" not in response.reply.lower()


async def test_asha_request_is_strict(client: httpx.AsyncClient) -> None:
    response = await client.post(
        "/v1/asha/chat",
        headers=OWNER_HEADERS,
        json={"message": "Hello", "raw_medical_record": "not accepted"},
    )

    assert response.status_code == 422
