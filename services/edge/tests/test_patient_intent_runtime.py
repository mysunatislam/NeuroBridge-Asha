from __future__ import annotations

import asyncio
import json
from datetime import UTC, datetime
from pathlib import Path

import pytest
from pydantic import ValidationError

from fingerspeak_edge.intent_monitor import PatientIntent, PatientIntentDetection
from fingerspeak_edge.protocol import (
    PairingAuthenticate,
    PatientIntentPayload,
    parse_client_message,
)
from tests.helpers import make_runtime, pairing_message


def _authentication(raw: dict) -> PairingAuthenticate:
    message = parse_client_message(json.dumps(raw))
    assert isinstance(message, PairingAuthenticate)
    return message


@pytest.mark.asyncio
async def test_patient_intent_broadcasts_only_to_authenticated_connections_without_media() -> None:
    runtime = make_runtime()
    detected_at = datetime(2026, 8, 22, 12, 0, tzinfo=UTC)
    detection = PatientIntentDetection(
        intent=PatientIntent.look_left,
        confidence=0.87,
        detected_at=detected_at,
    )

    # With no authenticated phone there is no queue and no serialized event.
    assert await runtime.publish_patient_intent(detection) is None

    first_connection, first_auth = await runtime.authenticate(_authentication(pairing_message()))
    credential = first_auth.payload.device_credential
    assert credential is not None
    second_connection, _ = await runtime.authenticate(
        _authentication(pairing_message(credential, credential_kind="device_credential"))
    )

    emitted = await runtime.publish_patient_intent(detection)
    first = await asyncio.wait_for(runtime.next_patient_intent(first_connection), timeout=0.5)
    second = await asyncio.wait_for(runtime.next_patient_intent(second_connection), timeout=0.5)

    assert emitted is not None
    assert first.message_id == emitted.message_id == second.message_id
    assert first.sequence == emitted.sequence == second.sequence
    assert first.type == "patient.intent"
    document = first.model_dump(mode="json")
    assert document["payload"] == {
        "intent": "look_left",
        "confidence": 0.87,
        "detected_at": detected_at.isoformat().replace("+00:00", "Z"),
    }
    serialized = json.dumps(document, separators=(",", ":")).lower()
    for forbidden in ("frame", "landmark", "image", "video", "audio"):
        assert forbidden not in serialized

    await runtime.disconnect(first_connection)
    with pytest.raises(RuntimeError, match="not authenticated"):
        await runtime.next_patient_intent(first_connection)

def test_patient_intent_payload_and_contract_are_closed_and_media_free() -> None:
    detected_at = datetime(2026, 8, 22, 12, 0, tzinfo=UTC)
    with pytest.raises(ValidationError, match="Extra inputs are not permitted"):
        PatientIntentPayload.model_validate(
            {
                "intent": "blink",
                "confidence": 0.9,
                "detected_at": detected_at,
                "frame": "raw-camera-data",
            }
        )

    schema_path = Path(__file__).parents[3] / "contracts" / "device-link-v1.schema.json"
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    assert {"$ref": "#/$defs/patientIntent"} in schema["oneOf"]
    patient_intent = schema["$defs"]["patientIntent"]
    payload = patient_intent["allOf"][1]["properties"]["payload"]
    assert payload["additionalProperties"] is False
    assert set(payload["required"]) == {"intent", "confidence", "detected_at"}
    assert set(payload["properties"]) == {"intent", "confidence", "detected_at"}
