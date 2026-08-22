from __future__ import annotations

import hashlib
import hmac
import json
import time

from fingerspeak_api.config import Settings

SIGNATURE_VERSION = "v1"
SIGNATURE_PREFIX = f"{SIGNATURE_VERSION}="
INVALID_ASSERTION = "Invalid gateway identity assertion"
_HEX_DIGITS = frozenset("0123456789abcdefABCDEF")


class IdentityAssertionError(ValueError):
    """A gateway identity assertion is missing, malformed, stale, or unverifiable."""


def normalize_actor_subject(raw_subject: str | None) -> str:
    if raw_subject is None:
        raise IdentityAssertionError(INVALID_ASSERTION)
    subject = raw_subject.strip()
    if not subject or len(subject) > 200 or any(ord(char) < 32 for char in subject):
        raise IdentityAssertionError(INVALID_ASSERTION)
    return subject


def canonical_gateway_assertion(*, subject: str, timestamp: int, method: str, path: str) -> bytes:
    """Build the stable UTF-8 representation signed by the trusted gateway."""

    document = {
        "method": method.upper(),
        "path": path,
        "subject": subject,
        "timestamp": timestamp,
        "version": SIGNATURE_VERSION,
    }
    return json.dumps(
        document,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def sign_gateway_identity(
    *, secret: str | bytes, subject: str, timestamp: int, method: str, path: str
) -> str:
    key = secret.encode("utf-8") if isinstance(secret, str) else secret
    payload = canonical_gateway_assertion(
        subject=subject,
        timestamp=timestamp,
        method=method,
        path=path,
    )
    digest = hmac.new(key, payload, hashlib.sha256).hexdigest()
    return f"{SIGNATURE_PREFIX}{digest}"


def authenticate_actor_subject(
    *,
    raw_subject: str | None,
    raw_timestamp: str | None,
    raw_signature: str | None,
    method: str,
    path: str,
    settings: Settings,
    now: int | None = None,
) -> str:
    """Verify a gateway assertion or use the explicitly enabled local fallback."""

    has_signature_fields = raw_timestamp is not None or raw_signature is not None
    if not has_signature_fields:
        if not settings.requires_gateway_signature:
            if raw_subject is not None:
                return normalize_actor_subject(raw_subject)
            if settings.allow_development_identity:
                return normalize_actor_subject(settings.development_identity)
        raise IdentityAssertionError(INVALID_ASSERTION)

    # Partial assertions never fall back, including in development.
    subject = normalize_actor_subject(raw_subject)
    if raw_timestamp is None or raw_signature is None:
        raise IdentityAssertionError(INVALID_ASSERTION)
    if len(path) > 2_048 or not path.startswith("/"):
        raise IdentityAssertionError(INVALID_ASSERTION)
    if not raw_timestamp.isascii() or not raw_timestamp.isdecimal() or len(raw_timestamp) > 12:
        raise IdentityAssertionError(INVALID_ASSERTION)

    timestamp = int(raw_timestamp)
    current_time = int(time.time()) if now is None else now
    if abs(current_time - timestamp) > settings.gateway_signature_ttl_seconds:
        raise IdentityAssertionError(INVALID_ASSERTION)

    configured_secret = settings.gateway_hmac_secret
    if configured_secret is None:
        raise IdentityAssertionError(INVALID_ASSERTION)
    expected = sign_gateway_identity(
        secret=configured_secret.get_secret_value(),
        subject=subject,
        timestamp=timestamp,
        method=method,
        path=path,
    ).removeprefix(SIGNATURE_PREFIX)

    prefix_valid = raw_signature.startswith(SIGNATURE_PREFIX)
    supplied = raw_signature.removeprefix(SIGNATURE_PREFIX) if prefix_valid else ""
    format_valid = len(supplied) == 64 and all(char in _HEX_DIGITS for char in supplied)
    # Always make a same-length constant-time comparison, even for malformed input.
    candidate = supplied.lower() if format_valid else "0" * 64
    signature_valid = hmac.compare_digest(candidate, expected)
    if not format_valid or not signature_valid:
        raise IdentityAssertionError(INVALID_ASSERTION)
    return subject


def websocket_origin_is_allowed(raw_origin: str | None, settings: Settings) -> bool:
    """Apply the browser origin boundary before accepting a credentialed WebSocket."""

    return raw_origin is not None and raw_origin in settings.cors_origins
