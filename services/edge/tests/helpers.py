from __future__ import annotations

from datetime import UTC, datetime
from typing import Any
from uuid import uuid4

from fingerspeak_edge.adapters import SimulatedCamera, SimulatedDisplay, SimulatedTelemetry
from fingerspeak_edge.state import EdgeRuntime, EdgeSettings, PairingAuthority

PAIRING_CODE = "test-pairing-code-with-enough-entropy"
DEVICE_ID = "pi-demo-1"


def make_runtime(
    *,
    pairing_code: str = PAIRING_CODE,
    max_message_bytes: int = 4_096,
    wall_clock=None,
    monotonic_clock=None,
) -> EdgeRuntime:
    return EdgeRuntime(
        settings=EdgeSettings(
            device_id=DEVICE_ID,
            max_message_bytes=max_message_bytes,
            status_interval_seconds=30,
        ),
        pairing=PairingAuthority(pairing_code),
        camera=SimulatedCamera(),
        display=SimulatedDisplay(),
        telemetry=SimulatedTelemetry(),
        wall_clock=wall_clock,
        monotonic_clock=monotonic_clock,
    )


def client_message(
    message_type: str,
    payload: dict[str, Any],
    *,
    message_id: str | None = None,
    device_id: str = DEVICE_ID,
    sequence: int = 1,
    sent_at: str | None = None,
) -> dict[str, Any]:
    return {
        "version": 1,
        "message_id": message_id or str(uuid4()),
        "device_id": device_id,
        "type": message_type,
        "sent_at": sent_at or datetime.now(UTC).isoformat(),
        "sequence": sequence,
        "payload": payload,
    }


def pairing_message(
    credential: str = PAIRING_CODE,
    *,
    credential_kind: str = "pairing_code",
) -> dict[str, Any]:
    return client_message(
        "pairing.authenticate",
        {
            "credential_kind": credential_kind,
            "credential": credential,
            "phone_id": "patient-phone-1",
        },
        sequence=0,
    )
