from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass
from uuid import UUID

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from pydantic import ValidationError

from fingerspeak_edge import __version__
from fingerspeak_edge.cloud import CloudDeviceRelay
from fingerspeak_edge.protocol import (
    PairingAuthenticate,
    parse_client_message,
)
from fingerspeak_edge.state import EdgeRuntime, ProtocolViolation, server_json

DEVICE_SUBPROTOCOL = "fingerspeak.device.v1"


class ReceiveTimeout(Exception):
    pass


class BinaryFrame(Exception):
    pass


class OversizedFrame(Exception):
    pass


@dataclass(frozen=True, slots=True)
class AppSettings:
    allowed_origins: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if any(origin in {"*", "null"} for origin in self.allowed_origins):
            raise ValueError("allowed_origins must contain explicit, non-null origins")


async def _receive_bounded_text(
    websocket: WebSocket,
    *,
    timeout_seconds: float,
    max_message_bytes: int,
) -> str:
    try:
        incoming = await asyncio.wait_for(websocket.receive(), timeout=timeout_seconds)
    except TimeoutError as exc:
        raise ReceiveTimeout from exc

    if incoming["type"] == "websocket.disconnect":
        raise WebSocketDisconnect(incoming.get("code", 1000))
    if incoming.get("bytes") is not None:
        raise BinaryFrame
    raw = incoming.get("text")
    if not isinstance(raw, str):
        raise BinaryFrame
    if len(raw.encode("utf-8")) > max_message_bytes:
        raise OversizedFrame
    return raw


def _origin_allowed(websocket: WebSocket, settings: AppSettings) -> bool:
    if not settings.allowed_origins:
        return True
    return websocket.headers.get("origin") in settings.allowed_origins


def _subprotocol_offered(websocket: WebSocket) -> bool:
    offered = websocket.headers.get("sec-websocket-protocol", "")
    return DEVICE_SUBPROTOCOL in {item.strip() for item in offered.split(",") if item.strip()}


def create_app(
    runtime: EdgeRuntime,
    settings: AppSettings | None = None,
    cloud_relay: CloudDeviceRelay | None = None,
) -> FastAPI:
    app_settings = settings or AppSettings()

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        await runtime.start()
        try:
            if cloud_relay is not None:
                await cloud_relay.start()
            yield
        finally:
            if cloud_relay is not None:
                await cloud_relay.stop()
            await runtime.stop()

    app = FastAPI(
        title="FingerSpeak edge service",
        version=__version__,
        description=(
            "Authenticated local camera/display bridge. No motor control, arbitrary commands, "
            "cloud AI, or media-upload endpoint is provided."
        ),
        lifespan=lifespan,
    )
    app.state.runtime = runtime

    @app.get("/health/live")
    async def health_live() -> dict[str, str]:
        return {"status": "ok", "service": "fingerspeak-edge", "version": __version__}

    @app.get("/health/ready")
    async def health_ready() -> dict[str, str]:
        return {"status": "ok" if runtime.started else "starting"}

    @app.websocket("/v1/device/ws")
    async def device_socket(websocket: WebSocket) -> None:
        if not _origin_allowed(websocket, app_settings):
            await websocket.close(code=4403, reason="WebSocket origin is not allowed")
            return
        if not _subprotocol_offered(websocket):
            await websocket.close(code=4406, reason="FingerSpeak device subprotocol is required")
            return

        await websocket.accept(subprotocol=DEVICE_SUBPROTOCOL)
        connection_id: UUID | None = None
        try:
            try:
                raw = await _receive_bounded_text(
                    websocket,
                    timeout_seconds=runtime.settings.authentication_timeout_seconds,
                    max_message_bytes=runtime.settings.max_message_bytes,
                )
            except ReceiveTimeout:
                await websocket.close(code=4401, reason="Authentication frame timed out")
                return
            except BinaryFrame:
                await websocket.close(code=1003, reason="Text JSON frames are required")
                return
            except OversizedFrame:
                await websocket.close(code=1009, reason="Authentication frame is too large")
                return

            try:
                first = parse_client_message(raw)
            except ValidationError:
                error = await runtime.validation_error_message(
                    "The first frame must be a valid pairing.authenticate message."
                )
                await websocket.send_text(server_json(error))
                await websocket.close(code=4401, reason="Authentication is required")
                return
            if not isinstance(first, PairingAuthenticate):
                error = await runtime.validation_error_message(
                    "The first frame must be pairing.authenticate.",
                    ref_message_id=first.message_id,
                )
                await websocket.send_text(server_json(error))
                await websocket.close(code=4401, reason="Authentication is required")
                return

            try:
                connection_id, authenticated = await runtime.authenticate(first)
            except ProtocolViolation as violation:
                await websocket.send_text(server_json(await runtime.error_message(violation)))
                await websocket.close(code=4401, reason="Authentication failed")
                return

            # This is the first successful server output. No telemetry is emitted before auth.
            await websocket.send_text(server_json(authenticated))
            await websocket.send_text(server_json(await runtime.status_message()))

            while True:
                try:
                    raw = await _receive_bounded_text(
                        websocket,
                        timeout_seconds=runtime.settings.status_interval_seconds,
                        max_message_bytes=runtime.settings.max_message_bytes,
                    )
                except ReceiveTimeout:
                    await websocket.send_text(server_json(await runtime.status_message()))
                    continue
                except BinaryFrame:
                    await websocket.close(code=1003, reason="Text JSON frames are required")
                    return
                except OversizedFrame:
                    await websocket.close(code=1009, reason="Message is too large")
                    return

                try:
                    message = parse_client_message(raw)
                except ValidationError:
                    error = await runtime.validation_error_message(
                        "Message does not match the FingerSpeak device protocol."
                    )
                    await websocket.send_text(server_json(error))
                    continue
                if isinstance(message, PairingAuthenticate):
                    error = await runtime.validation_error_message(
                        "pairing.authenticate is accepted only as the first frame.",
                        ref_message_id=message.message_id,
                    )
                    await websocket.send_text(server_json(error))
                    continue

                try:
                    ack = await runtime.command_ack(connection_id, message)
                except ProtocolViolation as violation:
                    await websocket.send_text(server_json(await runtime.error_message(violation)))
                    continue
                await websocket.send_text(server_json(ack))
                await websocket.send_text(server_json(await runtime.status_message()))
        except WebSocketDisconnect:
            pass
        finally:
            if connection_id is not None:
                await runtime.disconnect(connection_id)

    return app
