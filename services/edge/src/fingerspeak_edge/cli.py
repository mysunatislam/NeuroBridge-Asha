from __future__ import annotations

import argparse
import os
import secrets

import uvicorn
from pydantic import SecretStr

from fingerspeak_edge.adapters import SimulatedCamera, SimulatedDisplay, SimulatedTelemetry
from fingerspeak_edge.app import AppSettings, create_app
from fingerspeak_edge.cloud import CloudDeviceRelay, CloudRelaySettings
from fingerspeak_edge.state import EdgeRuntime, EdgeSettings, PairingAuthority


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the FingerSpeak Raspberry Pi edge bridge.")
    parser.add_argument("--adapter", choices=("simulated", "picamera2"), default="simulated")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--device-id", default="fingerspeak-pi")
    parser.add_argument(
        "--pairing-code",
        default=os.getenv("FINGERSPEAK_EDGE_PAIRING_CODE"),
        help=(
            "One-time pairing code. Prefer FINGERSPEAK_EDGE_PAIRING_CODE so the code is not "
            "visible in the process list. A random code is generated when omitted."
        ),
    )
    parser.add_argument(
        "--allowed-origin",
        action="append",
        default=[],
        help="Exact permitted phone-app origin; repeat to allow more than one.",
    )
    parser.add_argument("--max-message-bytes", type=int, default=4_096)
    parser.add_argument(
        "--cloud-device-ws-url",
        default=os.getenv("FINGERSPEAK_EDGE_CLOUD_DEVICE_WS_URL"),
        help="Optional server-provisioned /v1/devices/{id}/ws URL. Omit to disable the relay.",
    )
    parser.add_argument(
        "--cloud-origin",
        default=os.getenv("FINGERSPEAK_EDGE_CLOUD_ORIGIN"),
        help="Exact Origin allowed by the cloud API for the optional device socket.",
    )
    parser.add_argument(
        "--cloud-transport",
        choices=("unknown", "wifi", "usb", "ethernet"),
        default=os.getenv("FINGERSPEAK_EDGE_CLOUD_TRANSPORT", "unknown"),
    )
    parser.add_argument("--cloud-telemetry-interval", type=float, default=5.0)
    parser.add_argument("--log-level", default="info")
    return parser


def build_runtime(args: argparse.Namespace, pairing_code: str) -> EdgeRuntime:
    if args.adapter == "picamera2":
        from fingerspeak_edge.adapters.picamera2_camera import Picamera2Camera

        camera = Picamera2Camera()
    else:
        camera = SimulatedCamera()
    return EdgeRuntime(
        settings=EdgeSettings(
            device_id=args.device_id,
            max_message_bytes=args.max_message_bytes,
        ),
        pairing=PairingAuthority(pairing_code),
        camera=camera,
        display=SimulatedDisplay(),
        telemetry=SimulatedTelemetry(),
    )


def build_cloud_relay(
    args: argparse.Namespace, runtime: EdgeRuntime
) -> CloudDeviceRelay | None:
    token = os.getenv("FINGERSPEAK_EDGE_CLOUD_DEVICE_TOKEN")
    configured = any((args.cloud_device_ws_url, args.cloud_origin, token))
    if not configured:
        return None
    if not args.cloud_device_ws_url or not args.cloud_origin or not token:
        raise SystemExit(
            "Optional cloud relay requires FINGERSPEAK_EDGE_CLOUD_DEVICE_WS_URL, "
            "FINGERSPEAK_EDGE_CLOUD_ORIGIN, and FINGERSPEAK_EDGE_CLOUD_DEVICE_TOKEN."
        )
    settings = CloudRelaySettings(
        websocket_url=args.cloud_device_ws_url,
        origin=args.cloud_origin,
        bearer_token=SecretStr(token),
        transport=args.cloud_transport,
        telemetry_interval_seconds=args.cloud_telemetry_interval,
        max_message_bytes=args.max_message_bytes,
    )
    return CloudDeviceRelay(settings=settings, runtime=runtime)


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    pairing_code = args.pairing_code or secrets.token_urlsafe(18)
    if len(pairing_code) < 16:
        raise SystemExit("Pairing code must contain at least 16 characters.")
    if args.pairing_code is None:
        print(f"FingerSpeak one-time pairing code: {pairing_code}", flush=True)
    runtime = build_runtime(args, pairing_code)
    cloud_relay = build_cloud_relay(args, runtime)
    app = create_app(
        runtime,
        AppSettings(allowed_origins=tuple(args.allowed_origin)),
        cloud_relay=cloud_relay,
    )
    uvicorn.run(
        app,
        host=args.host,
        port=args.port,
        log_level=args.log_level,
        ws_max_size=args.max_message_bytes,
    )
    return 0
