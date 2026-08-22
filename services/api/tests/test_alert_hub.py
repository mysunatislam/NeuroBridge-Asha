from __future__ import annotations

from typing import Any
from uuid import uuid4

from fingerspeak_api.services.alerts import AlertHub


class FakeWebSocket:
    def __init__(self, *, fail: bool = False) -> None:
        self.accepted = False
        self.fail = fail
        self.messages: list[dict[str, Any]] = []
        self.close_code: int | None = None
        self.close_reason: str | None = None

    async def accept(self) -> None:
        self.accepted = True

    async def send_json(self, message: dict[str, Any]) -> None:
        if self.fail:
            raise RuntimeError("socket closed")
        self.messages.append(message)

    async def close(self, code: int = 1000, reason: str | None = None) -> None:
        self.close_code = code
        self.close_reason = reason


async def test_alert_hub_fans_out_and_removes_dead_connections() -> None:
    hub = AlertHub()
    profile_id = uuid4()
    live = FakeWebSocket()
    dead = FakeWebSocket(fail=True)

    live_token = await hub.begin_authorization(profile_id, "caregiver-live")
    dead_token = await hub.begin_authorization(profile_id, "caregiver-dead")
    await hub.connect(  # type: ignore[arg-type]
        profile_id, "caregiver-live", live_token, live
    )
    await hub.connect(  # type: ignore[arg-type]
        profile_id, "caregiver-dead", dead_token, dead
    )
    delivered = await hub.publish(profile_id, {"type": "caregiver_alert.created"})

    assert live.accepted
    assert live.messages == [{"type": "caregiver_alert.created"}]
    assert delivered == 1
    assert await hub.connection_count(profile_id) == 1

    await hub.disconnect(profile_id, live)  # type: ignore[arg-type]
    assert await hub.connection_count(profile_id) == 0


async def test_alert_hub_revokes_connected_and_in_flight_actor_sockets() -> None:
    hub = AlertHub()
    profile_id = uuid4()
    revoked = FakeWebSocket()
    retained = FakeWebSocket()
    revoked_token = await hub.begin_authorization(profile_id, "caregiver-revoked")
    retained_token = await hub.begin_authorization(profile_id, "caregiver-retained")
    in_flight_token = await hub.begin_authorization(profile_id, "caregiver-revoked")
    await hub.connect(  # type: ignore[arg-type]
        profile_id, "caregiver-revoked", revoked_token, revoked
    )
    await hub.connect(  # type: ignore[arg-type]
        profile_id, "caregiver-retained", retained_token, retained
    )

    disconnected = await hub.disconnect_actor(profile_id, "caregiver-revoked")
    stale = FakeWebSocket()
    connected = await hub.connect(  # type: ignore[arg-type]
        profile_id, "caregiver-revoked", in_flight_token, stale
    )

    assert disconnected == 1
    assert revoked.close_code == 4403
    assert retained.close_code is None
    assert not connected
    assert stale.close_code == 4403
    assert await hub.connection_count(profile_id) == 1


async def test_alert_hub_disconnects_every_profile_socket_on_consent_withdrawal() -> None:
    hub = AlertHub()
    profile_id = uuid4()
    first = FakeWebSocket()
    second = FakeWebSocket()
    first_token = await hub.begin_authorization(profile_id, "owner")
    second_token = await hub.begin_authorization(profile_id, "caregiver")
    await hub.connect(profile_id, "owner", first_token, first)  # type: ignore[arg-type]
    await hub.connect(  # type: ignore[arg-type]
        profile_id, "caregiver", second_token, second
    )

    disconnected = await hub.disconnect_profile(profile_id)

    assert disconnected == 2
    assert first.close_code == 4403
    assert second.close_code == 4403
    assert await hub.connection_count(profile_id) == 0
