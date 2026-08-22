from __future__ import annotations

import asyncio
import hashlib
import hmac
import secrets
from collections import defaultdict
from typing import Any
from uuid import UUID

from fastapi import WebSocket

DEVICE_TOKEN_PREFIX = "fsd_"


def create_device_token() -> tuple[str, str]:
    token = DEVICE_TOKEN_PREFIX + secrets.token_urlsafe(32)
    return token, device_token_sha256(token)


def device_token_sha256(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def device_token_matches(token: str, expected_sha256: str) -> bool:
    if len(token) > 160 or not token.startswith(DEVICE_TOKEN_PREFIX):
        return False
    return hmac.compare_digest(device_token_sha256(token), expected_sha256)


def bearer_token(raw_authorization: str | None) -> str | None:
    if raw_authorization is None:
        return None
    scheme, separator, value = raw_authorization.partition(" ")
    if separator != " " or scheme.lower() != "bearer" or not value:
        return None
    if value.strip() != value or " " in value or len(value) > 160:
        return None
    return value


class DeviceHub:
    """Process-local Pi sockets. Database state/caption replay remains authoritative."""

    def __init__(self) -> None:
        self._connections: dict[UUID, WebSocket] = {}
        self._pending_authorizations: dict[UUID, set[object]] = defaultdict(set)
        self._lock = asyncio.Lock()

    async def begin_authorization(self, device_id: UUID) -> object:
        token = object()
        async with self._lock:
            self._pending_authorizations[device_id].add(token)
        return token

    async def cancel_authorization(self, device_id: UUID, token: object) -> None:
        async with self._lock:
            pending = self._pending_authorizations.get(device_id)
            if pending is None:
                return
            pending.discard(token)
            if not pending:
                self._pending_authorizations.pop(device_id, None)

    async def connect(
        self, device_id: UUID, authorization_token: object, websocket: WebSocket
    ) -> bool:
        try:
            await websocket.accept()
        except BaseException:
            await self.cancel_authorization(device_id, authorization_token)
            raise

        previous: WebSocket | None = None
        registered = False
        async with self._lock:
            pending = self._pending_authorizations.get(device_id)
            if pending is not None and authorization_token in pending:
                pending.remove(authorization_token)
                if not pending:
                    self._pending_authorizations.pop(device_id, None)
                previous = self._connections.get(device_id)
                self._connections[device_id] = websocket
                registered = True

        if not registered:
            await websocket.close(code=4403, reason="Device authorization was revoked")
            return False
        if previous is not None and previous is not websocket:
            try:
                await asyncio.wait_for(
                    previous.close(code=4000, reason="Device connected from another client"),
                    timeout=2.0,
                )
            except Exception:
                pass
        return True

    async def disconnect(self, device_id: UUID, websocket: WebSocket) -> None:
        async with self._lock:
            if self._connections.get(device_id) is websocket:
                self._connections.pop(device_id, None)

    async def revoke(self, device_id: UUID) -> int:
        async with self._lock:
            self._pending_authorizations.pop(device_id, None)
            target = self._connections.pop(device_id, None)
        if target is None:
            return 0
        try:
            await asyncio.wait_for(
                target.close(code=4403, reason="Device access was revoked"), timeout=2.0
            )
        except Exception:
            pass
        return 1

    async def publish(self, device_id: UUID, message: dict[str, Any]) -> bool:
        async with self._lock:
            target = self._connections.get(device_id)
        if target is None:
            return False
        try:
            await asyncio.wait_for(target.send_json(message), timeout=2.0)
        except Exception:
            await self.disconnect(device_id, target)
            return False
        return True

    async def connection_count(self, device_id: UUID) -> int:
        async with self._lock:
            return int(device_id in self._connections)


device_hub = DeviceHub()
