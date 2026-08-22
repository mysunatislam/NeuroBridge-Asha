from __future__ import annotations

import hashlib
import json
import os
import stat

import pytest

from fingerspeak_edge.cli import build_parser, main
from fingerspeak_edge.credential_store import (
    CredentialStoreError,
    FileCredentialDigestStore,
)
from fingerspeak_edge.protocol import PairingAuthenticate, parse_client_message
from fingerspeak_edge.state import PairingAuthority, ProtocolViolation
from tests.helpers import DEVICE_ID, PAIRING_CODE, pairing_message


def _authentication_request(
    credential: str,
    *,
    credential_kind: str = "pairing_code",
) -> PairingAuthenticate:
    parsed = parse_client_message(
        json.dumps(pairing_message(credential, credential_kind=credential_kind))
    )
    assert isinstance(parsed, PairingAuthenticate)
    return parsed


@pytest.mark.asyncio
async def test_rotated_digest_survives_restart_without_reenabling_pairing_code(
    tmp_path,
) -> None:
    store_path = tmp_path / "private" / "device-credential.json"
    first_store = FileCredentialDigestStore(store_path, device_id=DEVICE_ID)
    first = PairingAuthority(PAIRING_CODE, credential_store=first_store)

    result = await first.authenticate(_authentication_request(PAIRING_CODE))

    credential = result.device_credential
    assert credential is not None
    stored_text = store_path.read_text(encoding="utf-8")
    stored_record = json.loads(stored_text)
    assert credential not in stored_text
    assert stored_record == {
        "version": 1,
        "algorithm": "sha256",
        "device_id": DEVICE_ID,
        "digest": hashlib.sha256(credential.encode()).hexdigest(),
    }
    if os.name == "posix":
        assert stat.S_IMODE(store_path.stat().st_mode) == 0o600
        assert stat.S_IMODE(store_path.parent.stat().st_mode) == 0o700

    restarted = PairingAuthority(
        "different-one-time-code-after-restart",
        credential_store=FileCredentialDigestStore(store_path, device_id=DEVICE_ID),
    )
    assert restarted.pairing_available is False
    with pytest.raises(ProtocolViolation, match="already been consumed"):
        await restarted.authenticate(_authentication_request(PAIRING_CODE))

    reconnect = await restarted.authenticate(
        _authentication_request(credential, credential_kind="device_credential")
    )
    assert reconnect.device_credential is None


@pytest.mark.asyncio
async def test_failed_commit_does_not_consume_pairing_code_or_return_a_credential() -> None:
    class RecoverableStore:
        def __init__(self) -> None:
            self.fail = True
            self.digest: bytes | None = None

        def load(self) -> bytes | None:
            return self.digest

        def save(self, digest: bytes) -> None:
            if self.fail:
                raise CredentialStoreError("synthetic persistence failure")
            self.digest = digest

        def reset(self) -> bool:
            self.digest = None
            return True

    store = RecoverableStore()
    authority = PairingAuthority(PAIRING_CODE, credential_store=store)
    request = _authentication_request(PAIRING_CODE)

    with pytest.raises(ProtocolViolation) as failed:
        await authority.authenticate(request)
    assert failed.value.code == "credential_store_failed"
    assert authority.pairing_available is True
    assert store.digest is None

    store.fail = False
    accepted = await authority.authenticate(request)
    assert accepted.device_credential is not None
    assert store.digest == hashlib.sha256(accepted.device_credential.encode()).digest()
    assert authority.pairing_available is False


def test_store_replaces_atomically_and_leaves_no_temporary_file(tmp_path) -> None:
    store_path = tmp_path / "private" / "credential.json"
    store = FileCredentialDigestStore(store_path, device_id=DEVICE_ID)
    first = hashlib.sha256(b"first credential").digest()
    second = hashlib.sha256(b"second credential").digest()

    store.save(first)
    store.save(second)

    assert store.load() == second
    assert [entry.name for entry in store_path.parent.iterdir()] == [store_path.name]


def test_store_rejects_wrong_device_and_malformed_records(tmp_path) -> None:
    store_path = tmp_path / "private" / "credential.json"
    store = FileCredentialDigestStore(store_path, device_id=DEVICE_ID)
    store.save(hashlib.sha256(b"credential").digest())

    with pytest.raises(CredentialStoreError, match="different device ID"):
        FileCredentialDigestStore(store_path, device_id="different-pi").load()

    store_path.write_text('{"digest":"plaintext-is-not-a-valid-record"}', encoding="utf-8")
    if os.name == "posix":
        store_path.chmod(0o600)
    with pytest.raises(CredentialStoreError, match="unexpected schema"):
        store.load()


@pytest.mark.skipif(os.name != "posix", reason="POSIX mode-bit enforcement")
def test_store_rejects_group_or_world_access(tmp_path) -> None:
    store_path = tmp_path / "private" / "credential.json"
    store = FileCredentialDigestStore(store_path, device_id=DEVICE_ID)
    store.save(hashlib.sha256(b"credential").digest())
    store_path.chmod(0o644)

    with pytest.raises(CredentialStoreError, match="mode 0600"):
        store.load()


def test_cli_reset_is_local_explicit_and_uses_configured_store(
    tmp_path,
    monkeypatch,
    capsys,
) -> None:
    store_path = tmp_path / "private" / "credential.json"
    store = FileCredentialDigestStore(store_path, device_id=DEVICE_ID)
    store.save(hashlib.sha256(b"credential").digest())
    monkeypatch.setenv("FINGERSPEAK_EDGE_CREDENTIAL_STORE", str(store_path))

    parsed = build_parser().parse_args(["--device-id", DEVICE_ID])
    assert parsed.credential_store == str(store_path)
    assert main(["--device-id", DEVICE_ID, "--reset-pairing"]) == 0

    assert not store_path.exists()
    assert "removed" in capsys.readouterr().out


def test_cli_reset_refuses_to_run_without_a_store(monkeypatch) -> None:
    monkeypatch.delenv("FINGERSPEAK_EDGE_CREDENTIAL_STORE", raising=False)

    with pytest.raises(SystemExit, match="requires --credential-store"):
        main(["--reset-pairing"])


def test_reset_refuses_to_delete_an_unrelated_file(tmp_path) -> None:
    unrelated = tmp_path / "private" / "unrelated.json"
    unrelated.parent.mkdir()
    unrelated.write_text('{"important":true}', encoding="utf-8")
    if os.name == "posix":
        unrelated.chmod(0o600)
    store = FileCredentialDigestStore(unrelated, device_id=DEVICE_ID)

    with pytest.raises(CredentialStoreError, match="unexpected schema"):
        store.reset()

    assert unrelated.exists()
