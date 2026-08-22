from __future__ import annotations

from datetime import UTC, datetime
from typing import Any
from uuid import uuid4

import httpx

OWNER_HEADERS = {"X-Actor-Subject": "patient-123"}
CAREGIVER_HEADERS = {"X-Actor-Subject": "caregiver-456"}
TEST_GATEWAY_SECRET = "test-only-gateway-secret-with-more-than-32-bytes"


async def create_profile(
    client: httpx.AsyncClient,
    *,
    analytics_consent: bool = True,
    caregiver_alerts_consent: bool = True,
    model_sync_consent: bool = True,
) -> dict[str, Any]:
    response = await client.post(
        "/v1/profiles",
        headers=OWNER_HEADERS,
        json={
            "display_name": "Demo communicator",
            "locale": "en-US",
            "consent_version": "2026-08",
            "consent_granted_at": datetime.now(UTC).isoformat(),
            "analytics_consent": analytics_consent,
            "caregiver_alerts_consent": caregiver_alerts_consent,
            "model_sync_consent": model_sync_consent,
            "vocabulary": [
                {"key": "rest", "label": "Rest", "phrase": "", "dwell_ms": 650},
                {"key": "water", "label": "Water", "phrase": "Water, please."},
            ],
        },
    )
    assert response.status_code == 201, response.text
    return response.json()


async def create_session(
    client: httpx.AsyncClient, profile_id: str, model_version_id: str | None = None
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "profile_id": profile_id,
        "client_session_id": str(uuid4()),
        "client_version": "web-0.1.0",
        "device_id": "browser-installation-1",
        "inference_location": "on_device",
    }
    if model_version_id is not None:
        payload["model_version_id"] = model_version_id
    response = await client.post("/v1/sessions", headers=OWNER_HEADERS, json=payload)
    assert response.status_code == 201, response.text
    return response.json()
