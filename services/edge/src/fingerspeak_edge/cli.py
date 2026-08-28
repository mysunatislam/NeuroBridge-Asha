from __future__ import annotations

import argparse
import os
import secrets
from pathlib import Path

import uvicorn
from pydantic import SecretStr

from fingerspeak_edge.adapters import SimulatedCamera, SimulatedDisplay, SimulatedTelemetry
from fingerspeak_edge.app import AppSettings, create_app
from fingerspeak_edge.cloud import CloudDeviceRelay, CloudRelaySettings
from fingerspeak_edge.credential_store import (
    CredentialDigestStore,
    CredentialStoreError,
    FileCredentialDigestStore,
)
from fingerspeak_edge.intent_monitor import (
    IntentMonitorSettings,
    PatientIntent,
    PatientIntentMonitor,
    SimulatedFaceIntentDetector,
    simulated_intent_script,
)
from fingerspeak_edge.state import EdgeRuntime, EdgeSettings, PairingAuthority


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the FingerSpeak Raspberry Pi edge bridge.")
    parser.add_argument(
        "--adapter",
        "--camera",
        dest="adapter",
        choices=("simulated", "picamera2"),
        default="simulated",
        help="Camera adapter. --camera is an equivalent, more explicit alias.",
    )
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
    parser.add_argument(
        "--credential-store",
        default=os.getenv("FINGERSPEAK_EDGE_CREDENTIAL_STORE"),
        help=(
            "Optional absolute path for the rotated device-credential digest. Disabled when "
            "omitted; may also be set with FINGERSPEAK_EDGE_CREDENTIAL_STORE."
        ),
    )
    parser.add_argument(
        "--reset-pairing",
        action="store_true",
        help=(
            "Remove the protected persisted digest and exit, allowing a new one-time pairing "
            "code on the next start. Requires --credential-store or its environment variable."
        ),
    )
    parser.add_argument("--max-message-bytes", type=int, default=4_096)
    parser.add_argument(
        "--intent-detector",
        choices=("off", "simulated", "mediapipe"),
        default=os.getenv("FINGERSPEAK_EDGE_INTENT_DETECTOR", "off"),
        help=(
            "Local semantic face/eye detector. 'off' is the hardware-safe default; "
            "'simulated' is deterministic test/demo input; 'mediapipe' processes Picamera2 "
            "frames locally and emits only bounded intent events."
        ),
    )
    parser.add_argument(
        "--face-model-path",
        default=os.getenv("FINGERSPEAK_EDGE_FACE_MODEL_PATH"),
        help=(
            "Path to the pinned official face_landmarker.task model. When running from the "
            "repository, the bundled web model is reused automatically."
        ),
    )
    parser.add_argument(
        "--simulate-intent",
        choices=tuple(intent.value for intent in PatientIntent),
        help=(
            "Emit one deliberate simulated intent after neutral calibration. Requires "
            "--intent-detector simulated."
        ),
    )
    parser.add_argument("--intent-calibration-samples", type=int, default=30)
    parser.add_argument("--intent-sample-interval", type=float, default=0.1)
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


def build_runtime(
    args: argparse.Namespace,
    pairing_code: str,
    credential_store: CredentialDigestStore | None = None,
) -> EdgeRuntime:
    if args.adapter == "picamera2":
        from fingerspeak_edge.adapters.picamera2_camera import Picamera2Camera

        camera = Picamera2Camera()
    else:
        camera = SimulatedCamera()
    monitor: PatientIntentMonitor | None = None
    if args.simulate_intent and args.intent_detector != "simulated":
        raise ValueError("--simulate-intent requires --intent-detector simulated")
    if args.intent_detector == "mediapipe" and args.adapter != "picamera2":
        raise ValueError("--intent-detector mediapipe requires --adapter picamera2")
    if args.intent_detector != "off":
        monitor_settings = IntentMonitorSettings(
            calibration_samples=args.intent_calibration_samples,
            sample_interval_seconds=args.intent_sample_interval,
        )
    if args.intent_detector == "simulated":
        intent = PatientIntent(args.simulate_intent) if args.simulate_intent else None
        detector = SimulatedFaceIntentDetector(
            simulated_intent_script(
                intent,
                calibration_samples=monitor_settings.calibration_samples,
                sample_interval_seconds=monitor_settings.sample_interval_seconds,
            )
        )
        monitor = PatientIntentMonitor(detector, settings=monitor_settings)
    elif args.intent_detector == "mediapipe":
        from fingerspeak_edge.adapters.mediapipe_face_intent import (
            MediaPipePicamera2FaceIntentDetector,
        )

        model_path = resolve_face_model_path(args.face_model_path)
        detector = MediaPipePicamera2FaceIntentDetector(
            camera,
            model_path=model_path,
        )
        monitor = PatientIntentMonitor(detector, settings=monitor_settings)
    return EdgeRuntime(
        settings=EdgeSettings(
            device_id=args.device_id,
            max_message_bytes=args.max_message_bytes,
        ),
        pairing=PairingAuthority(pairing_code, credential_store=credential_store),
        camera=camera,
        display=SimulatedDisplay(),
        telemetry=SimulatedTelemetry(),
        intent_monitor=monitor,
    )


def resolve_face_model_path(configured: str | None) -> Path:
    if configured:
        path = Path(configured).expanduser().resolve()
    else:
        # Reuse the exact model already pinned for the PWA; do not ship a duplicate binary.
        path = (
            Path(__file__).resolve().parents[4]
            / "apps"
            / "web"
            / "public"
            / "models"
            / "face_landmarker.task"
        )
    if not path.is_file():
        raise ValueError(
            "Face Landmarker model not found. Pass --face-model-path (or set "
            "FINGERSPEAK_EDGE_FACE_MODEL_PATH) to face_landmarker.task."
        )
    return path


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


def build_credential_store(args: argparse.Namespace) -> FileCredentialDigestStore | None:
    if not args.credential_store:
        return None
    try:
        return FileCredentialDigestStore(args.credential_store, device_id=args.device_id)
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    credential_store = build_credential_store(args)
    if args.reset_pairing:
        if credential_store is None:
            raise SystemExit(
                "--reset-pairing requires --credential-store or "
                "FINGERSPEAK_EDGE_CREDENTIAL_STORE."
            )
        try:
            removed = credential_store.reset()
        except CredentialStoreError as exc:
            raise SystemExit(str(exc)) from exc
        result = "removed" if removed else "already absent"
        print(f"FingerSpeak persisted pairing digest: {result}.", flush=True)
        return 0

    pairing_code = args.pairing_code or secrets.token_urlsafe(18)
    if len(pairing_code) < 16:
        raise SystemExit("Pairing code must contain at least 16 characters.")
    try:
        runtime = build_runtime(args, pairing_code, credential_store)
    except (CredentialStoreError, ValueError) as exc:
        raise SystemExit(str(exc)) from exc
    if runtime.pairing.pairing_available:
        if args.pairing_code is None:
            print(f"FingerSpeak one-time pairing code: {pairing_code}", flush=True)
    else:
        print(
            "FingerSpeak persisted device credential loaded; one-time pairing remains consumed.",
            flush=True,
        )
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
