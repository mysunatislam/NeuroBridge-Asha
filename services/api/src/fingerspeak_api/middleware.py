from __future__ import annotations

import json

from starlette.datastructures import Headers, MutableHeaders
from starlette.types import ASGIApp, Message, Receive, Scope, Send


class PrivacyBoundaryMiddleware:
    """Reject media/binary uploads and unexpectedly large request bodies."""

    blocked_content_types = (
        "application/octet-stream",
        "image/",
        "video/",
        "audio/",
        "multipart/form-data",
    )

    def __init__(self, app: ASGIApp, max_body_bytes: int) -> None:
        self.app = app
        self.max_body_bytes = max_body_bytes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        headers = Headers(scope=scope)
        content_type = headers.get("content-type", "").lower()
        if any(content_type.startswith(value) for value in self.blocked_content_types):
            await self._json_error(
                send,
                415,
                "Media and binary uploads are not accepted; inference data stays on-device.",
            )
            return

        content_length = headers.get("content-length")
        if content_length:
            try:
                too_large = int(content_length) > self.max_body_bytes
            except ValueError:
                too_large = True
            if too_large:
                await self._json_error(
                    send,
                    413,
                    "Request body exceeds the control-plane API limit.",
                )
                return

        messages: list[Message] = []
        received = 0
        more_body = True
        while more_body:
            message = await receive()
            messages.append(message)
            if message["type"] != "http.request":
                break
            received += len(message.get("body", b""))
            if received > self.max_body_bytes:
                await self._json_error(
                    send,
                    413,
                    "Request body exceeds the control-plane API limit.",
                )
                return
            more_body = message.get("more_body", False)

        async def replay_receive() -> Message:
            if messages:
                return messages.pop(0)
            return {"type": "http.disconnect"}

        await self.app(scope, replay_receive, send)

    @staticmethod
    async def _json_error(send: Send, status_code: int, detail: str) -> None:
        body = json.dumps({"detail": detail}).encode("utf-8")
        await send(
            {
                "type": "http.response.start",
                "status": status_code,
                "headers": [
                    (b"content-type", b"application/json"),
                    (b"content-length", str(len(body)).encode("ascii")),
                ],
            }
        )
        await send({"type": "http.response.body", "body": body})


class NoStoreAPIMiddleware:
    """Prevent browsers and intermediaries from caching private API responses."""

    def __init__(self, app: ASGIApp, api_prefix: str) -> None:
        self.app = app
        self.api_prefix = api_prefix.rstrip("/")

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        path = scope.get("path", "")
        is_api_request = scope["type"] == "http" and (
            path == self.api_prefix or path.startswith(f"{self.api_prefix}/")
        )
        if not is_api_request:
            await self.app(scope, receive, send)
            return

        async def send_no_store(message: Message) -> None:
            if message["type"] == "http.response.start":
                headers = MutableHeaders(scope=message)
                headers["cache-control"] = "no-store, private"
                headers["pragma"] = "no-cache"
            await send(message)

        await self.app(scope, receive, send_no_store)
