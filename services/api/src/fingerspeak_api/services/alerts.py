from __future__ import annotations

import asyncio
from collections import defaultdict
from typing import Any
from uuid import UUID

from fastapi import WebSocket


class AlertHub:
    """Process-local fan-out backed by database replay in the route layer."""

    def __init__(self) -> None:
        self._connections: dict[UUID, dict[WebSocket, str]] = defaultdict(dict)
        self._pending_authorizations: dict[UUID, dict[object, str]] = defaultdict(dict)
        self._lock = asyncio.Lock()

    async def begin_authorization(self, profile_id: UUID, actor_subject: str) -> object:
        """Register an in-flight authorization so concurrent revocation cannot miss it."""

        token = object()
        async with self._lock:
            self._pending_authorizations[profile_id][token] = actor_subject
        return token

    async def cancel_authorization(self, profile_id: UUID, token: object) -> None:
        async with self._lock:
            pending = self._pending_authorizations.get(profile_id)
            if pending is None:
                return
            pending.pop(token, None)
            if not pending:
                self._pending_authorizations.pop(profile_id, None)

    async def connect(
        self,
        profile_id: UUID,
        actor_subject: str,
        authorization_token: object,
        websocket: WebSocket,
    ) -> bool:
        """Accept a socket only if its authorization survived concurrent revocation."""

        try:
            await websocket.accept()
        except BaseException:
            await self.cancel_authorization(profile_id, authorization_token)
            raise

        registered = False
        async with self._lock:
            pending = self._pending_authorizations.get(profile_id)
            pending_subject = (
                pending.pop(authorization_token, None) if pending is not None else None
            )
            if pending is not None and not pending:
                self._pending_authorizations.pop(profile_id, None)
            if pending_subject == actor_subject:
                self._connections[profile_id][websocket] = actor_subject
                registered = True

        if not registered:
            await websocket.close(code=4403, reason="WebSocket authorization was revoked")
        return registered

    async def disconnect(self, profile_id: UUID, websocket: WebSocket) -> None:
        async with self._lock:
            connections = self._connections.get(profile_id)
            if connections is None:
                return
            connections.pop(websocket, None)
            if not connections:
                self._connections.pop(profile_id, None)

    async def disconnect_actor(
        self,
        profile_id: UUID,
        actor_subject: str,
        *,
        code: int = 4403,
        reason: str = "WebSocket authorization was revoked",
    ) -> int:
        """Invalidate pending and connected sockets for one profile/actor pair."""

        async with self._lock:
            pending = self._pending_authorizations.get(profile_id)
            if pending is not None:
                revoked_tokens = [
                    token for token, subject in pending.items() if subject == actor_subject
                ]
                for token in revoked_tokens:
                    pending.pop(token, None)
                if not pending:
                    self._pending_authorizations.pop(profile_id, None)

            connections = self._connections.get(profile_id)
            targets = (
                tuple(
                    websocket
                    for websocket, subject in connections.items()
                    if subject == actor_subject
                )
                if connections is not None
                else ()
            )
            if connections is not None:
                for websocket in targets:
                    connections.pop(websocket, None)
                if not connections:
                    self._connections.pop(profile_id, None)

        await self._close_many(targets, code=code, reason=reason)
        return len(targets)

    async def disconnect_profile(
        self,
        profile_id: UUID,
        *,
        code: int = 4403,
        reason: str = "WebSocket authorization was revoked",
    ) -> int:
        """Invalidate every pending and connected socket for a profile."""

        async with self._lock:
            self._pending_authorizations.pop(profile_id, None)
            connections = self._connections.pop(profile_id, {})
            targets = tuple(connections)

        await self._close_many(targets, code=code, reason=reason)
        return len(targets)

    async def publish(self, profile_id: UUID, message: dict[str, Any]) -> int:
        async with self._lock:
            targets = tuple(self._connections.get(profile_id, {}))
        if not targets:
            return 0

        results = await asyncio.gather(
            *(self._send(target, message) for target in targets), return_exceptions=True
        )
        delivered = 0
        for target, result in zip(targets, results, strict=True):
            if isinstance(result, Exception):
                await self.disconnect(profile_id, target)
            else:
                delivered += 1
        return delivered

    @staticmethod
    async def _send(websocket: WebSocket, message: dict[str, Any]) -> None:
        await asyncio.wait_for(websocket.send_json(message), timeout=2.0)

    @staticmethod
    async def _close_many(targets: tuple[WebSocket, ...], *, code: int, reason: str) -> None:
        if not targets:
            return
        await asyncio.gather(
            *(
                asyncio.wait_for(
                    websocket.close(code=code, reason=reason),
                    timeout=2.0,
                )
                for websocket in targets
            ),
            return_exceptions=True,
        )

    async def connection_count(self, profile_id: UUID) -> int:
        async with self._lock:
            return len(self._connections.get(profile_id, ()))


alert_hub = AlertHub()
