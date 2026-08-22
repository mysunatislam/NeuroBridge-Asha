from __future__ import annotations

import asyncio
from datetime import UTC, datetime
from uuid import uuid4

import httpx

from tests.helpers import CAREGIVER_HEADERS, OWNER_HEADERS, create_profile, create_session


async def test_profile_model_session_event_and_alert_workflow(
    client: httpx.AsyncClient,
) -> None:
    profile = await create_profile(client)

    grant = await client.put(
        f"/v1/profiles/{profile['id']}/caregivers",
        headers=OWNER_HEADERS,
        json={"caregiver_subject": CAREGIVER_HEADERS["X-Actor-Subject"]},
    )
    assert grant.status_code == 200

    model = await client.post(
        "/v1/model-versions",
        headers=OWNER_HEADERS,
        json={
            "profile_id": profile["id"],
            "semantic_version": "patient-model-1",
            "framework": "tensorflowjs",
            "runtime": "browser",
            "feature_schema_version": "3d-angle-motion-v1",
            "artifact_uri": "https://models.example.test/patient-model-1/model.json",
            "artifact_sha256": "a" * 64,
            "metrics": {
                "validation_accuracy": 0.91,
                "validation_scope": "held_out_session",
                "validation_samples": 40,
                "false_activations_per_hour": 0.2,
                "median_activation_latency_ms": 710,
            },
            "status": "validated",
        },
    )
    assert model.status_code == 201, model.text
    activated = await client.post(
        f"/v1/model-versions/{model.json()['id']}/activate", headers=OWNER_HEADERS
    )
    assert activated.status_code == 200
    assert activated.json()["status"] == "active"

    session = await create_session(client, profile["id"], activated.json()["id"])

    event_id = str(uuid4())
    event_payload = {
        "session_id": session["id"],
        "client_event_id": event_id,
        "event_type": "phrase_spoken",
        "occurred_at": datetime.now(UTC).isoformat(),
        "gesture_key": "g-" + "a" * 64,
        "confidence": 0.94,
        "latency_ms": 705,
        "model_version_id": activated.json()["id"],
    }
    event = await client.post("/v1/events", headers=OWNER_HEADERS, json=event_payload)
    duplicate = await client.post("/v1/events", headers=OWNER_HEADERS, json=event_payload)
    assert event.status_code == 201
    assert duplicate.status_code == 201
    assert duplicate.json()["id"] == event.json()["id"]

    alert_payload = {
        "profile_id": profile["id"],
        "session_id": session["id"],
        "client_event_id": str(uuid4()),
        "severity": "urgent",
        "message": "Please check on me.",
    }
    alert = await client.post(
        "/v1/events/caregiver-alerts", headers=OWNER_HEADERS, json=alert_payload
    )
    assert alert.status_code == 201, alert.text
    assert alert.json()["status"] == "pending"

    caregiver_view = await client.get(
        "/v1/events/caregiver-alerts",
        headers=CAREGIVER_HEADERS,
        params={"profile_id": profile["id"]},
    )
    assert caregiver_view.status_code == 200
    assert [item["id"] for item in caregiver_view.json()] == [alert.json()["id"]]

    acknowledged = await client.post(
        f"/v1/events/caregiver-alerts/{alert.json()['id']}/acknowledge",
        headers=CAREGIVER_HEADERS,
    )
    assert acknowledged.status_code == 200
    assert acknowledged.json()["status"] == "acknowledged"
    assert acknowledged.json()["acknowledged_by"] == CAREGIVER_HEADERS["X-Actor-Subject"]


async def test_consent_is_enforced_and_raw_landmarks_are_forbidden(
    client: httpx.AsyncClient,
) -> None:
    profile = await create_profile(
        client,
        analytics_consent=False,
        caregiver_alerts_consent=False,
        model_sync_consent=False,
    )
    session = await create_session(client, profile["id"])

    raw_payload = {
        "session_id": session["id"],
        "client_event_id": str(uuid4()),
        "event_type": "inference_rejected",
        "landmarks": [[0.1, 0.2, 0.3]],
    }
    forbidden_shape = await client.post("/v1/events", headers=OWNER_HEADERS, json=raw_payload)
    assert forbidden_shape.status_code == 422

    derived_payload = {
        "session_id": session["id"],
        "client_event_id": str(uuid4()),
        "event_type": "inference_rejected",
        "confidence": 0.2,
    }
    no_analytics_consent = await client.post(
        "/v1/events", headers=OWNER_HEADERS, json=derived_payload
    )
    assert no_analytics_consent.status_code == 403

    no_alert_consent = await client.post(
        "/v1/events/caregiver-alerts",
        headers=OWNER_HEADERS,
        json={
            "profile_id": profile["id"],
            "session_id": session["id"],
            "client_event_id": str(uuid4()),
            "severity": "routine",
            "message": "Hello",
        },
    )
    assert no_alert_consent.status_code == 403


async def test_derived_events_reject_phrase_and_semantic_gesture_keys(
    client: httpx.AsyncClient,
) -> None:
    profile = await create_profile(client)
    session = await create_session(client, profile["id"])
    base_payload = {
        "session_id": session["id"],
        "event_type": "phrase_spoken",
        "occurred_at": datetime.now(UTC).isoformat(),
    }

    phrase_upload = await client.post(
        "/v1/events",
        headers=OWNER_HEADERS,
        json={
            **base_payload,
            "client_event_id": str(uuid4()),
            "gesture_key": "g-" + "a" * 64,
            "phrase_key": "water",
        },
    )
    semantic_gesture = await client.post(
        "/v1/events",
        headers=OWNER_HEADERS,
        json={
            **base_payload,
            "client_event_id": str(uuid4()),
            "gesture_key": "water",
        },
    )
    uppercase_digest = await client.post(
        "/v1/events",
        headers=OWNER_HEADERS,
        json={
            **base_payload,
            "client_event_id": str(uuid4()),
            "gesture_key": "g-" + "A" * 64,
        },
    )
    valid = await client.post(
        "/v1/events",
        headers=OWNER_HEADERS,
        json={
            **base_payload,
            "client_event_id": str(uuid4()),
            "gesture_key": "g-" + "0a" * 32,
        },
    )

    assert phrase_upload.status_code == 422
    assert semantic_gesture.status_code == 422
    assert uppercase_digest.status_code == 422
    assert valid.status_code == 201, valid.text
    assert valid.json()["gesture_key"] == "g-" + "0a" * 32
    assert "phrase_key" not in valid.json()


async def test_inference_location_cannot_be_changed_to_cloud(client: httpx.AsyncClient) -> None:
    profile = await create_profile(client)
    response = await client.post(
        "/v1/sessions",
        headers=OWNER_HEADERS,
        json={
            "profile_id": profile["id"],
            "client_session_id": str(uuid4()),
            "client_version": "web-0.1.0",
            "inference_location": "cloud",
        },
    )

    assert response.status_code == 422


async def test_alert_lists_keep_newest_window_and_use_server_receive_time(
    client: httpx.AsyncClient,
) -> None:
    profile = await create_profile(client)
    session = await create_session(client, profile["id"])
    requested_years = [2099, 2000, 2050]
    alerts: list[dict[str, object]] = []
    before = datetime.now(UTC)

    for requested_year in requested_years:
        response = await client.post(
            "/v1/events/caregiver-alerts",
            headers=OWNER_HEADERS,
            json={
                "profile_id": profile["id"],
                "session_id": session["id"],
                "client_event_id": str(uuid4()),
                "severity": "emergency",
                "message": f"Alert requested in {requested_year}",
                "requested_at": datetime(requested_year, 1, 1, tzinfo=UTC).isoformat(),
            },
        )
        assert response.status_code == 201, response.text
        alerts.append(response.json())
        await asyncio.sleep(0.002)

    after_creation = datetime.now(UTC)
    for alert in alerts:
        created_at = datetime.fromisoformat(str(alert["created_at"]))
        if created_at.tzinfo is None:
            created_at = created_at.replace(tzinfo=UTC)
        assert before <= created_at <= after_creation

    newest_window = await client.get(
        "/v1/events/caregiver-alerts",
        headers=OWNER_HEADERS,
        params={"profile_id": profile["id"], "limit": 2},
    )
    assert newest_window.status_code == 200
    assert [item["id"] for item in newest_window.json()] == [
        alerts[1]["id"],
        alerts[2]["id"],
    ]

    incremental = await client.get(
        "/v1/events/caregiver-alerts",
        headers=OWNER_HEADERS,
        params={
            "profile_id": profile["id"],
            "after": alerts[0]["created_at"],
            "limit": 2,
        },
    )
    assert incremental.status_code == 200
    assert [item["id"] for item in incremental.json()] == [
        alerts[1]["id"],
        alerts[2]["id"],
    ]

    source_events = await client.get(
        "/v1/events",
        headers=OWNER_HEADERS,
        params={"session_id": session["id"]},
    )
    assert source_events.status_code == 200
    assert {datetime.fromisoformat(item["occurred_at"]).year for item in source_events.json()} == {
        *requested_years
    }
