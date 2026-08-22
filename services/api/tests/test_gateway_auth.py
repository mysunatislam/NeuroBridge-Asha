from __future__ import annotations

import time
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from typing import Any
from uuid import UUID, uuid4

import httpx
import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError
from starlette.websockets import WebSocketDisconnect

from fingerspeak_api.config import Environment, Settings, get_settings
from fingerspeak_api.database import get_db_session
from fingerspeak_api.main import create_app
from fingerspeak_api.models import AlertSeverity, AlertStatus
from fingerspeak_api.security import sign_gateway_identity
from tests.helpers import TEST_GATEWAY_SECRET

ACTOR = "patient-production-123"
PATH = "/v1/profiles"
WEBSOCKET_PATH = "/v1/events/caregiver-alerts/ws"
ALLOWED_ORIGIN = "http://test"


def signed_headers(
    *, timestamp: int, path: str = PATH, signature: str | None = None
) -> dict[str, str]:
    return {
        "X-Actor-Subject": ACTOR,
        "X-Actor-Timestamp": str(timestamp),
        "X-Actor-Signature": signature
        or sign_gateway_identity(
            secret=TEST_GATEWAY_SECRET,
            subject=ACTOR,
            timestamp=timestamp,
            method="GET",
            path=path,
        ),
    }


class FakeScalarResult:
    def __init__(self, values: list[object]) -> None:
        self.values = values

    def all(self) -> list[object]:
        return self.values


class FakeDB:
    def __init__(self, profile_id: UUID, alerts: list[object]) -> None:
        self.profile_id = profile_id
        self.alerts = alerts
        self.scalar_statements: list[str] = []

    async def get(self, _model: object, _identifier: object) -> object:
        return SimpleNamespace(
            id=self.profile_id,
            owner_subject=ACTOR,
            caregiver_alerts_consent=True,
        )

    async def scalars(self, statement: object) -> FakeScalarResult:
        self.scalar_statements.append(str(statement))
        return FakeScalarResult(self.alerts)

    async def rollback(self) -> None:
        return None


def make_alert(*, profile_id: UUID, created_at: datetime) -> SimpleNamespace:
    return SimpleNamespace(
        id=uuid4(),
        profile_id=profile_id,
        session_id=uuid4(),
        source_event_id=uuid4(),
        severity=AlertSeverity.emergency,
        message="Help now",
        status=AlertStatus.pending,
        created_at=created_at,
        acknowledged_at=None,
        acknowledged_by=None,
        resolved_at=None,
    )


def websocket_app(
    *, alerts: list[object] | None = None, max_message_bytes: int = 4_096
) -> tuple[Any, FakeDB, UUID, dict[str, str]]:
    settings = Settings(
        environment=Environment.production,
        database_url="sqlite+aiosqlite://",
        cors_origins=[ALLOWED_ORIGIN],
        trusted_hosts=["testserver"],
        gateway_hmac_secret=TEST_GATEWAY_SECRET,
        gateway_signature_ttl_seconds=30,
        websocket_max_message_bytes=max_message_bytes,
        alert_replay_limit=2,
    )
    app = create_app(settings)
    profile_id = uuid4()
    fake_db = FakeDB(profile_id, alerts or [])

    async def override_db() -> AsyncIterator[FakeDB]:
        yield fake_db

    app.dependency_overrides[get_db_session] = override_db
    app.dependency_overrides[get_settings] = lambda: settings
    headers = signed_headers(timestamp=int(time.time()), path=WEBSOCKET_PATH)
    headers["Origin"] = ALLOWED_ORIGIN
    return app, fake_db, profile_id, headers


async def test_production_rejects_unsigned_actor_header(
    production_client: httpx.AsyncClient,
) -> None:
    response = await production_client.get(PATH, headers={"X-Actor-Subject": ACTOR})

    assert response.status_code == 401
    assert response.json()["detail"] == "Invalid gateway identity assertion"


async def test_production_rejects_invalid_signature(
    production_client: httpx.AsyncClient,
) -> None:
    response = await production_client.get(
        PATH,
        headers=signed_headers(timestamp=int(time.time()), signature="v1=" + "0" * 64),
    )

    assert response.status_code == 401


async def test_production_rejects_signature_for_another_path(
    production_client: httpx.AsyncClient,
) -> None:
    response = await production_client.get(
        PATH,
        headers=signed_headers(timestamp=int(time.time()), path="/v1/sessions"),
    )

    assert response.status_code == 401


async def test_production_rejects_stale_signature(
    production_client: httpx.AsyncClient,
) -> None:
    response = await production_client.get(
        PATH,
        headers=signed_headers(timestamp=int(time.time()) - 31),
    )

    assert response.status_code == 401


async def test_production_accepts_current_valid_signature(
    production_client: httpx.AsyncClient,
) -> None:
    response = await production_client.get(
        PATH,
        headers=signed_headers(timestamp=int(time.time())),
    )

    assert response.status_code == 200
    assert response.json() == []


def test_production_configuration_requires_a_strong_secret() -> None:
    with pytest.raises(ValidationError):
        Settings(
            environment=Environment.production,
            gateway_hmac_secret="too-short",
        )


@pytest.mark.parametrize("origins", [[], ["*"], ["null"]])
def test_credentialed_cors_requires_explicit_origin(origins: list[str]) -> None:
    with pytest.raises(ValidationError):
        Settings(
            environment=Environment.test,
            cors_origins=origins,
            cors_allow_credentials=True,
        )


def test_signed_gateway_assertion_authenticates_websocket() -> None:
    app, _fake_db, profile_id, headers = websocket_app()

    with TestClient(app) as client:
        with client.websocket_connect(
            f"{WEBSOCKET_PATH}?profile_id={profile_id}", headers=headers
        ) as websocket:
            assert websocket.receive_json() == {
                "type": "caregiver_alert.snapshot",
                "alerts": [],
            }
            websocket.send_json({"type": "ping"})
            assert websocket.receive_json() == {"type": "pong"}


@pytest.mark.parametrize("origin", [None, "https://attacker.example"])
def test_websocket_rejects_missing_or_unlisted_origin(origin: str | None) -> None:
    app, _fake_db, profile_id, headers = websocket_app()
    if origin is None:
        headers.pop("Origin")
    else:
        headers["Origin"] = origin

    with TestClient(app) as client:
        with pytest.raises(WebSocketDisconnect) as exc_info:
            with client.websocket_connect(
                f"{WEBSOCKET_PATH}?profile_id={profile_id}", headers=headers
            ):
                pass

    assert exc_info.value.code == 4403


def test_websocket_rejects_oversized_text_message() -> None:
    app, _fake_db, profile_id, headers = websocket_app(max_message_bytes=128)

    with TestClient(app) as client:
        with client.websocket_connect(
            f"{WEBSOCKET_PATH}?profile_id={profile_id}", headers=headers
        ) as websocket:
            websocket.receive_json()
            websocket.send_text("x" * 129)
            with pytest.raises(WebSocketDisconnect) as exc_info:
                websocket.receive_json()

    assert exc_info.value.code == 1009


def test_websocket_snapshot_delivers_newest_window_in_chronological_order() -> None:
    now = datetime.now(UTC)
    profile_id = uuid4()
    oldest = make_alert(profile_id=profile_id, created_at=now - timedelta(minutes=2))
    middle = make_alert(profile_id=profile_id, created_at=now - timedelta(minutes=1))
    newest = make_alert(profile_id=profile_id, created_at=now)
    app, fake_db, actual_profile_id, headers = websocket_app(alerts=[newest, middle])
    # The helper owns the profile id used for authorization; update the fake alert ownership only.
    for alert in (oldest, middle, newest):
        alert.profile_id = actual_profile_id

    with TestClient(app) as client:
        with client.websocket_connect(
            f"{WEBSOCKET_PATH}?profile_id={actual_profile_id}", headers=headers
        ) as websocket:
            snapshot = websocket.receive_json()

    assert [item["id"] for item in snapshot["alerts"]] == [str(middle.id), str(newest.id)]
    assert "caregiver_alerts.created_at DESC" in fake_db.scalar_statements[0]
    assert str(oldest.id) not in {item["id"] for item in snapshot["alerts"]}
