from __future__ import annotations

import json
import os
import stat
import tempfile
from pathlib import Path
from typing import Protocol

_STORE_VERSION = 1
_DIGEST_ALGORITHM = "sha256"
_DIGEST_BYTES = 32
_MAX_STORE_BYTES = 4_096
_STORE_FIELDS = {"version", "algorithm", "device_id", "digest"}


class CredentialStoreError(RuntimeError):
    """A persisted device-credential digest could not be read or committed safely."""


class CredentialDigestStore(Protocol):
    def load(self) -> bytes | None: ...

    def save(self, digest: bytes) -> None: ...

    def reset(self) -> bool: ...


class FileCredentialDigestStore:
    """Atomic, owner-protected storage for one SHA-256 device-credential digest."""

    def __init__(self, path: str | Path, *, device_id: str) -> None:
        requested = Path(path).expanduser()
        if not requested.is_absolute():
            raise ValueError("credential store path must be absolute")
        # Resolve the directory for a stable location, but deliberately preserve the final
        # component so an existing symlink is rejected by lstat/O_NOFOLLOW instead of followed.
        self.path = requested.parent.resolve(strict=False) / requested.name
        self.device_id = device_id

    @staticmethod
    def _validate_digest(digest: bytes) -> None:
        if not isinstance(digest, bytes) or len(digest) != _DIGEST_BYTES:
            raise ValueError("device credential digest must be exactly 32 bytes")

    @staticmethod
    def _validate_file_security(path: Path, details: os.stat_result) -> None:
        if not stat.S_ISREG(details.st_mode):
            raise CredentialStoreError("Credential store must be a regular file.")
        if os.name != "posix":
            return
        if details.st_uid != os.geteuid():
            raise CredentialStoreError(
                "Credential store must be owned by the edge-service account."
            )
        mode = stat.S_IMODE(details.st_mode)
        if mode & 0o177:
            raise CredentialStoreError(
                f"Credential store permissions are unsafe for {path}; use mode 0600."
            )

    @staticmethod
    def _validate_parent_security(parent: Path) -> None:
        try:
            details = parent.stat()
        except OSError as exc:
            raise CredentialStoreError("Credential store directory is unavailable.") from exc
        if not stat.S_ISDIR(details.st_mode):
            raise CredentialStoreError("Credential store parent must be a directory.")
        if os.name == "posix" and stat.S_IMODE(details.st_mode) & 0o022:
            raise CredentialStoreError(
                "Credential store directory must not be group- or world-writable."
            )

    def _existing_details(self) -> os.stat_result | None:
        try:
            details = os.lstat(self.path)
        except FileNotFoundError:
            return None
        except OSError as exc:
            raise CredentialStoreError("Credential store metadata could not be read.") from exc
        self._validate_file_security(self.path, details)
        return details

    @staticmethod
    def _decode_record(raw: str, *, device_id: str) -> bytes:
        try:
            record = json.loads(raw)
        except (json.JSONDecodeError, UnicodeError) as exc:
            raise CredentialStoreError("Credential store is not valid JSON.") from exc
        if not isinstance(record, dict) or set(record) != _STORE_FIELDS:
            raise CredentialStoreError("Credential store has an unexpected schema.")
        if type(record["version"]) is not int or record["version"] != _STORE_VERSION:
            raise CredentialStoreError("Credential store version is unsupported.")
        if record["algorithm"] != _DIGEST_ALGORITHM:
            raise CredentialStoreError("Credential store digest algorithm is unsupported.")
        if record["device_id"] != device_id:
            raise CredentialStoreError("Credential store belongs to a different device ID.")
        encoded = record["digest"]
        if not isinstance(encoded, str) or len(encoded) != _DIGEST_BYTES * 2:
            raise CredentialStoreError("Credential store digest is malformed.")
        try:
            digest = bytes.fromhex(encoded)
        except ValueError as exc:
            raise CredentialStoreError("Credential store digest is malformed.") from exc
        if encoded != digest.hex() or len(digest) != _DIGEST_BYTES:
            raise CredentialStoreError("Credential store digest is malformed.")
        return digest

    def load(self) -> bytes | None:
        details = self._existing_details()
        if details is None:
            return None
        self._validate_parent_security(self.path.parent)
        if details.st_size > _MAX_STORE_BYTES:
            raise CredentialStoreError("Credential store is unexpectedly large.")

        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor: int | None = None
        try:
            descriptor = os.open(self.path, flags)
            with os.fdopen(descriptor, encoding="utf-8") as stream:
                descriptor = None
                opened_details = os.fstat(stream.fileno())
                self._validate_file_security(self.path, opened_details)
                raw = stream.read(_MAX_STORE_BYTES + 1)
        except CredentialStoreError:
            raise
        except (OSError, UnicodeError) as exc:
            raise CredentialStoreError("Credential store could not be read.") from exc
        finally:
            if descriptor is not None:
                os.close(descriptor)
        if len(raw.encode("utf-8")) > _MAX_STORE_BYTES:
            raise CredentialStoreError("Credential store is unexpectedly large.")
        return self._decode_record(raw, device_id=self.device_id)

    @staticmethod
    def _sync_directory_best_effort(parent: Path) -> None:
        if os.name != "posix":
            return
        descriptor: int | None = None
        try:
            descriptor = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
            os.fsync(descriptor)
        except OSError:
            # The atomic replacement is already committed. Some filesystems do not support
            # directory fsync, so inability to add this durability guarantee is non-fatal.
            pass
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def save(self, digest: bytes) -> None:
        self._validate_digest(digest)
        try:
            self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        except OSError as exc:
            raise CredentialStoreError("Credential store directory could not be created.") from exc
        self._validate_parent_security(self.path.parent)
        self._existing_details()

        record = {
            "version": _STORE_VERSION,
            "algorithm": _DIGEST_ALGORITHM,
            "device_id": self.device_id,
            "digest": digest.hex(),
        }
        encoded = json.dumps(record, ensure_ascii=True, separators=(",", ":")) + "\n"
        temporary_path: Path | None = None
        descriptor: int | None = None
        try:
            descriptor, temporary_name = tempfile.mkstemp(
                dir=self.path.parent,
                prefix=f".{self.path.name}.",
                suffix=".tmp",
            )
            temporary_path = Path(temporary_name)
            if hasattr(os, "fchmod"):
                os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
                descriptor = None
                stream.write(encoded)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary_path, self.path)
            temporary_path = None
        except OSError as exc:
            raise CredentialStoreError(
                "Credential store could not be committed atomically."
            ) from exc
        finally:
            if descriptor is not None:
                os.close(descriptor)
            if temporary_path is not None:
                try:
                    temporary_path.unlink(missing_ok=True)
                except OSError:
                    pass
        self._sync_directory_best_effort(self.path.parent)

    def reset(self) -> bool:
        if self.load() is None:
            return False
        try:
            self.path.unlink()
        except OSError as exc:
            raise CredentialStoreError("Credential store could not be reset.") from exc
        self._sync_directory_best_effort(self.path.parent)
        return True
