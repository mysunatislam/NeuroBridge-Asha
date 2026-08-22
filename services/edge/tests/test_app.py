from __future__ import annotations

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from fingerspeak_edge.app import DEVICE_SUBPROTOCOL, AppSettings, create_app
from tests.helpers import PAIRING_CODE, client_message, make_runtime, pairing_message


def test_socket_requires_authentication_before_status_or_commands() -> None:
    app = create_app(make_runtime())
    with TestClient(app) as client:
        with client.websocket_connect(
            "/v1/device/ws", subprotocols=[DEVICE_SUBPROTOCOL]
        ) as websocket:
            websocket.send_json(client_message("status.get", {}))
            response = websocket.receive_json()

            assert response["type"] == "protocol.error"
            assert response["payload"]["code"] == "invalid_message"
            assert websocket.receive()["code"] == 4401


def test_pairing_rotates_code_then_device_credential_reconnects() -> None:
    app = create_app(make_runtime())
    with TestClient(app) as client:
        with client.websocket_connect(
            "/v1/device/ws", subprotocols=[DEVICE_SUBPROTOCOL]
        ) as websocket:
            websocket.send_json(pairing_message())
            authenticated = websocket.receive_json()
            status = websocket.receive_json()

            credential = authenticated["payload"]["device_credential"]
            assert authenticated["type"] == "pairing.authenticated"
            assert credential
            assert status["type"] == "device.status"
            assert status["payload"]["phone_connected"] is True

        with client.websocket_connect(
            "/v1/device/ws", subprotocols=[DEVICE_SUBPROTOCOL]
        ) as websocket:
            websocket.send_json(pairing_message(PAIRING_CODE))
            error = websocket.receive_json()
            assert error["payload"]["code"] == "authentication_failed"
            assert websocket.receive()["code"] == 4401

        with client.websocket_connect(
            "/v1/device/ws", subprotocols=[DEVICE_SUBPROTOCOL]
        ) as websocket:
            websocket.send_json(
                pairing_message(credential, credential_kind="device_credential")
            )
            authenticated = websocket.receive_json()
            status = websocket.receive_json()
            assert authenticated["type"] == "pairing.authenticated"
            assert authenticated["payload"]["device_credential"] is None
            assert status["type"] == "device.status"


def test_authenticated_command_is_acknowledged_and_updates_status() -> None:
    app = create_app(make_runtime())
    with TestClient(app) as client:
        with client.websocket_connect(
            "/v1/device/ws", subprotocols=[DEVICE_SUBPROTOCOL]
        ) as websocket:
            websocket.send_json(pairing_message())
            websocket.receive_json()
            websocket.receive_json()
            websocket.send_json(
                client_message(
                    "caption.set",
                    {"text": "আমি আপনার সাথে আছি।", "language": "bn-BD"},
                )
            )

            ack = websocket.receive_json()
            status = websocket.receive_json()

            assert ack["type"] == "command.ack"
            assert ack["payload"]["accepted"] is True
            assert status["payload"]["active_display"] == "caption"


def test_socket_rejects_binary_oversize_and_unlisted_origins() -> None:
    app = create_app(
        make_runtime(max_message_bytes=512),
        AppSettings(allowed_origins=("https://patient.example",)),
    )
    with TestClient(app) as client:
        with client.websocket_connect(
            "/v1/device/ws",
            subprotocols=[DEVICE_SUBPROTOCOL],
            headers={"origin": "https://patient.example"},
        ) as websocket:
            websocket.send_bytes(b"not-json")
            assert websocket.receive()["code"] == 1003

        with client.websocket_connect(
            "/v1/device/ws",
            subprotocols=[DEVICE_SUBPROTOCOL],
            headers={"origin": "https://patient.example"},
        ) as websocket:
            websocket.send_text("x" * 513)
            assert websocket.receive()["code"] == 1009

        with pytest.raises(WebSocketDisconnect) as rejected:
            with client.websocket_connect(
                "/v1/device/ws",
                subprotocols=[DEVICE_SUBPROTOCOL],
                headers={"origin": "https://attacker.example"},
            ):
                pass
        assert rejected.value.code == 4403


def test_optional_cloud_relay_follows_application_lifespan() -> None:
    class FakeRelay:
        def __init__(self) -> None:
            self.started = False
            self.stopped = False

        async def start(self) -> None:
            self.started = True

        async def stop(self) -> None:
            self.stopped = True

    relay = FakeRelay()
    app = create_app(make_runtime(), cloud_relay=relay)  # type: ignore[arg-type]

    with TestClient(app):
        assert relay.started is True
        assert relay.stopped is False

    assert relay.stopped is True
