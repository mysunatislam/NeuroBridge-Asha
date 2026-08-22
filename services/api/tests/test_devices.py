from __future__ import annotations

from uuid import uuid4

import httpx

from fingerspeak_api.services.devices import create_device_token, device_token_matches
from tests.helpers import CAREGIVER_HEADERS, OWNER_HEADERS, create_profile


def test_device_tokens_are_opaque_and_hash_verifiable() -> None:
    token, digest = create_device_token()

    assert token.startswith("fsd_")
    assert token not in digest
    assert len(digest) == 64
    assert device_token_matches(token, digest)
    assert not device_token_matches(token + "x", digest)


async def test_owner_registers_and_authorized_caregiver_reads_and_captions(
    client: httpx.AsyncClient,
) -> None:
    profile = await create_profile(client)
    grant = await client.put(
        f"/v1/profiles/{profile['id']}/caregivers",
        headers=OWNER_HEADERS,
        json={"caregiver_subject": CAREGIVER_HEADERS["X-Actor-Subject"]},
    )
    assert grant.status_code == 200
    registration = await client.post(
        "/v1/devices",
        headers=OWNER_HEADERS,
        json={"profile_id": profile["id"], "name": "Wheelchair Pi"},
    )
    assert registration.status_code == 201, registration.text
    registered = registration.json()
    assert registered["token"].startswith("fsd_")
    assert "token_sha256" not in registration.text

    caregiver_view = await client.get(
        "/v1/devices",
        headers=CAREGIVER_HEADERS,
        params={"profile_id": profile["id"]},
    )
    assert caregiver_view.status_code == 200
    assert caregiver_view.json()[0]["online"] is False
    assert "token" not in caregiver_view.text

    caregiver_revoke = await client.delete(
        f"/v1/devices/{registered['device']['id']}",
        headers=CAREGIVER_HEADERS,
    )
    assert caregiver_revoke.status_code == 404

    caption_id = str(uuid4())
    caregiver_caption = await client.post(
        f"/v1/devices/{registered['device']['id']}/captions",
        headers=CAREGIVER_HEADERS,
        json={"client_message_id": caption_id, "text": "I am here"},
    )
    assert caregiver_caption.status_code == 201, caregiver_caption.text
    owner_caption_id = str(uuid4())
    accepted = await client.post(
        f"/v1/devices/{registered['device']['id']}/captions",
        headers=OWNER_HEADERS,
        json={"client_message_id": owner_caption_id, "text": "I am here"},
    )
    duplicate = await client.post(
        f"/v1/devices/{registered['device']['id']}/captions",
        headers=OWNER_HEADERS,
        json={"client_message_id": owner_caption_id, "text": "I am here"},
    )
    assert accepted.status_code == 201, accepted.text
    assert duplicate.status_code == 201
    assert duplicate.json()["id"] == accepted.json()["id"]


async def test_owner_revokes_device(client: httpx.AsyncClient) -> None:
    profile = await create_profile(client)
    registration = await client.post(
        "/v1/devices",
        headers=OWNER_HEADERS,
        json={"profile_id": profile["id"], "name": "Wheelchair Pi"},
    )
    device_id = registration.json()["device"]["id"]

    revoked = await client.delete(f"/v1/devices/{device_id}", headers=OWNER_HEADERS)
    listing = await client.get(
        "/v1/devices",
        headers=OWNER_HEADERS,
        params={"profile_id": profile["id"]},
    )

    assert revoked.status_code == 204
    assert listing.json()[0]["enabled"] is False
    assert listing.json()[0]["online"] is False
