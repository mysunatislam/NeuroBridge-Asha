from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from fastapi.testclient import TestClient
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from starlette.websockets import WebSocketDisconnect

from fingerspeak_api.config import Environment, Settings, get_settings
from fingerspeak_api.database import Base, get_db_session
from fingerspeak_api.main import create_app

OWNER_HEADERS = {"X-Actor-Subject": "revocation-owner"}
CAREGIVER_HEADERS = {"X-Actor-Subject": "revocation-caregiver"}
WEBSOCKET_ORIGIN = "http://test"


def build_test_client(database_path: Path) -> tuple[TestClient, AsyncEngine]:
    database_url = f"sqlite+aiosqlite:///{database_path.as_posix()}"

    async def create_schema() -> None:
        setup_engine = create_async_engine(database_url)
        async with setup_engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        await setup_engine.dispose()

    asyncio.run(create_schema())
    engine = create_async_engine(database_url)
    session_factory = async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)
    settings = Settings(
        environment=Environment.test,
        database_url=database_url,
        cors_origins=[WEBSOCKET_ORIGIN],
        trusted_hosts=["testserver"],
        allow_development_identity=False,
    )
    app = create_app(settings)

    async def override_db() -> AsyncIterator[AsyncSession]:
        async with session_factory() as session:
            yield session

    app.dependency_overrides[get_db_session] = override_db
    app.dependency_overrides[get_settings] = lambda: settings
    return TestClient(app), engine


def create_profile_and_grant(client: TestClient) -> dict[str, Any]:
    profile_response = client.post(
        "/v1/profiles",
        headers=OWNER_HEADERS,
        json={
            "display_name": "Revocation test",
            "consent_version": "2026-08",
            "consent_granted_at": datetime.now(UTC).isoformat(),
            "caregiver_alerts_consent": True,
        },
    )
    assert profile_response.status_code == 201, profile_response.text
    profile = profile_response.json()
    grant_response = client.put(
        f"/v1/profiles/{profile['id']}/caregivers",
        headers=OWNER_HEADERS,
        json={"caregiver_subject": CAREGIVER_HEADERS["X-Actor-Subject"]},
    )
    assert grant_response.status_code == 200, grant_response.text
    return profile


def assert_revoked(websocket: Any) -> None:
    try:
        websocket.receive_json()
    except WebSocketDisconnect as exc:
        assert exc.code == 4403
    else:
        raise AssertionError("Expected server to close the revoked WebSocket")


def test_caregiver_grant_revocation_disconnects_existing_socket(tmp_path: Path) -> None:
    client, engine = build_test_client(tmp_path / "caregiver-revoke.sqlite3")
    with client:
        profile = create_profile_and_grant(client)
        socket_path = f"/v1/events/caregiver-alerts/ws?profile_id={profile['id']}"
        with client.websocket_connect(
            socket_path,
            headers={**CAREGIVER_HEADERS, "Origin": WEBSOCKET_ORIGIN},
        ) as websocket:
            assert websocket.receive_json()["type"] == "caregiver_alert.snapshot"
            response = client.delete(
                f"/v1/profiles/{profile['id']}/caregivers/{CAREGIVER_HEADERS['X-Actor-Subject']}",
                headers=OWNER_HEADERS,
            )
            assert response.status_code == 204
            assert_revoked(websocket)
    asyncio.run(engine.dispose())


def test_consent_withdrawal_disconnects_all_profile_sockets(tmp_path: Path) -> None:
    client, engine = build_test_client(tmp_path / "consent-revoke.sqlite3")
    with client:
        profile = create_profile_and_grant(client)
        socket_path = f"/v1/events/caregiver-alerts/ws?profile_id={profile['id']}"
        with (
            client.websocket_connect(
                socket_path,
                headers={**OWNER_HEADERS, "Origin": WEBSOCKET_ORIGIN},
            ) as owner_socket,
            client.websocket_connect(
                socket_path,
                headers={**CAREGIVER_HEADERS, "Origin": WEBSOCKET_ORIGIN},
            ) as caregiver_socket,
        ):
            assert owner_socket.receive_json()["type"] == "caregiver_alert.snapshot"
            assert caregiver_socket.receive_json()["type"] == "caregiver_alert.snapshot"
            response = client.patch(
                f"/v1/profiles/{profile['id']}",
                headers=OWNER_HEADERS,
                json={"caregiver_alerts_consent": False},
            )
            assert response.status_code == 200, response.text
            assert_revoked(owner_socket)
            assert_revoked(caregiver_socket)
    asyncio.run(engine.dispose())
