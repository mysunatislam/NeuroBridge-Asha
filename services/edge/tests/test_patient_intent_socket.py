from __future__ import annotations

from datetime import UTC, datetime

from fastapi.testclient import TestClient

from fingerspeak_edge.app import DEVICE_SUBPROTOCOL, create_app
from fingerspeak_edge.intent_monitor import PatientIntent, PatientIntentDetection
from tests.helpers import make_runtime, pairing_message


def test_authenticated_socket_receives_intent_without_sending_a_command() -> None:
    runtime = make_runtime()
    app = create_app(runtime)
    detected_at = datetime(2026, 8, 22, 12, 0, tzinfo=UTC)

    with TestClient(app) as client:
        with client.websocket_connect(
            "/v1/device/ws", subprotocols=[DEVICE_SUBPROTOCOL]
        ) as websocket:
            websocket.send_json(pairing_message())
            assert websocket.receive_json()["type"] == "pairing.authenticated"
            assert websocket.receive_json()["type"] == "device.status"

            # No post-authentication client frame is sent. The local monitor publishes directly.
            assert client.portal is not None
            emitted = client.portal.call(
                runtime.publish_patient_intent,
                PatientIntentDetection(
                    intent=PatientIntent.mouth_open,
                    confidence=0.94,
                    detected_at=detected_at,
                ),
            )
            event = websocket.receive_json()

            assert emitted is not None
            assert event["type"] == "patient.intent"
            assert event["message_id"] == str(emitted.message_id)
            assert event["payload"] == {
                "intent": "mouth_open",
                "confidence": 0.94,
                "detected_at": "2026-08-22T12:00:00Z",
            }
