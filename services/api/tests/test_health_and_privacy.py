from __future__ import annotations

import httpx

from tests.helpers import OWNER_HEADERS


async def test_health_endpoints(client: httpx.AsyncClient) -> None:
    live = await client.get("/health/live")
    ready = await client.get("/health/ready")

    assert live.status_code == 200
    assert live.json()["status"] == "ok"
    assert "cache-control" not in live.headers
    assert ready.status_code == 200


async def test_media_uploads_are_rejected(client: httpx.AsyncClient) -> None:
    response = await client.post(
        "/v1/events",
        headers={**OWNER_HEADERS, "Content-Type": "image/jpeg"},
        content=b"not-a-frame",
    )

    assert response.status_code == 415
    assert "stays on-device" in response.json()["detail"]


async def test_openapi_has_no_upload_endpoint(client: httpx.AsyncClient) -> None:
    response = await client.get("/openapi.json")
    document = response.json()
    serialized = response.text.lower()

    assert all("upload" not in path and "frame" not in path for path in document["paths"])
    assert "multipart/form-data" not in serialized
    assert "uploadfile" not in serialized
    assert '"phrase_key"' not in serialized
    gesture_schema = document["components"]["schemas"]["DerivedEventCreate"]["properties"][
        "gesture_key"
    ]
    assert r"^g-[0-9a-f]{64}$" in {variant.get("pattern") for variant in gesture_schema["anyOf"]}


async def test_credentialed_cors_echoes_only_configured_origin(
    client: httpx.AsyncClient,
) -> None:
    response = await client.options(
        "/v1/profiles",
        headers={
            "Origin": "http://test",
            "Access-Control-Request-Method": "GET",
        },
    )

    assert response.status_code == 200
    assert response.headers["access-control-allow-origin"] == "http://test"
    assert response.headers["access-control-allow-credentials"] == "true"


async def test_authenticated_api_responses_are_not_cacheable(
    client: httpx.AsyncClient,
) -> None:
    response = await client.get("/v1/profiles", headers=OWNER_HEADERS)

    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store, private"
    assert response.headers["pragma"] == "no-cache"
