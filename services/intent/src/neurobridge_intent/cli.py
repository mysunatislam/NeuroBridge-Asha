"""Command-line entry point.

neurobridge-intent train --output models/intent_bundle_v1
neurobridge-intent verify models/intent_bundle_v1
neurobridge-intent calibrate --patient-id p1 --output patient_profile.json
    [--camera 0 | --synthetic]
neurobridge-intent run --bundle models/intent_bundle_v1 --profile patient_profile.json
    [--camera 0 | --synthetic]
neurobridge-intent models fetch
neurobridge-intent reason --payload event.json --task caregiver_message
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np

from .calibration import CalibrationSession, PatientProfile, frames_from_rows
from .schema import CALIBRATION_PHASE_SECONDS, CalibrationPhase


def _json(value: Any) -> str:
    return json.dumps(value, indent=2, sort_keys=True, allow_nan=False)


def cmd_train(args: argparse.Namespace) -> int:
    from .bundle import train_and_export

    manifest = train_and_export(
        args.output,
        per_class=args.per_class,
        seed=args.seed,
        epochs=args.epochs,
        algorithm=args.algorithm,
        with_temporal=not args.no_temporal,
        with_onnx=not args.no_onnx,
        verbose=args.verbose,
    )
    print(_json(manifest["metrics"]))
    print(f"bundle written to {args.output}")
    return 0


def cmd_export_app(args: argparse.Namespace) -> int:
    from .bundle import export_app_bundle, verify_bundle

    export_app_bundle(args.bundle, args.output)
    problems = verify_bundle(args.output)
    if problems:
        print("\n".join(problems))
        return 1
    print(f"app bundle written to {args.output}")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    from .bundle import verify_bundle

    problems = verify_bundle(args.bundle)
    if problems:
        print("\n".join(problems))
        return 1
    print("bundle OK")
    return 0


def _camera_frames(camera: int, seconds: float, on_frame=None):  # type: ignore[no-untyped-def]
    """Yield FrameFeatures from a webcam for ``seconds`` (needs the vision extra)."""

    import cv2  # type: ignore[import-not-found]

    from .extractor import MediaPipeFeatureExtractor

    extractor = MediaPipeFeatureExtractor()
    extractor.start()
    capture = cv2.VideoCapture(camera)
    if not capture.isOpened():
        raise RuntimeError(f"camera {camera} could not be opened")
    start = time.monotonic()
    try:
        while time.monotonic() - start < seconds:
            ok, frame = capture.read()
            if not ok:
                break
            features = extractor.process(frame, time.monotonic() - start)
            if on_frame is not None:
                on_frame(frame, features)
            if features is not None:
                yield features
    finally:
        capture.release()
        extractor.close()


def cmd_calibrate(args: argparse.Namespace) -> int:
    session = CalibrationSession(patient_id=args.patient_id, phase_seconds=args.seconds)
    if args.synthetic:
        from .synthetic import generate_calibration_phase

        rng = np.random.default_rng(args.seed)
        for phase in CalibrationPhase:
            clip = generate_calibration_phase(rng, phase, seconds=args.seconds)
            session.add_frames(phase, frames_from_rows(clip.timestamps, clip.values))
    else:
        instructions = {
            CalibrationPhase.normal_blinking: "Blink normally and look at the camera.",
            CalibrationPhase.normal_facial_movement: (
                "Move your face naturally: small smiles, talk silently, look around."
            ),
            CalibrationPhase.intentional_gestures: (
                "Perform your command gestures deliberately (triple blink, hold mouth open, "
                "raise eyebrows, turn head, raise hand)."
            ),
            CalibrationPhase.random_movement: (
                "Move randomly without meaning: shift, glance, wiggle."
            ),
            CalibrationPhase.rest_state: "Rest quietly and relax your face.",
        }
        for phase in CalibrationPhase:
            print(f"\n[{phase}] {instructions[phase]}  ({args.seconds:.0f} s) - starting in 3 s")
            time.sleep(3)
            for features in _camera_frames(args.camera, args.seconds):
                session.add_frame(phase, features)
            print(f"  recorded {len(session.recordings[phase].frames)} frames")
    profile = session.build_profile()
    path = profile.save(args.output)
    print(f"patient profile written to {path}")
    print(_json({"blink": profile.blink, "gesture_thresholds": profile.gesture_thresholds}))
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    from .pipeline import IntentPipeline, ModelBundle, run_clip

    bundle = ModelBundle.load(args.bundle)
    profile = PatientProfile.load(args.profile) if args.profile else PatientProfile.default()
    pipeline = IntentPipeline(bundle, profile)
    if args.synthetic:
        from .synthetic import generate_abnormal, generate_command

        rng = np.random.default_rng(args.seed)
        for command in ("triple_blink", "long_blink", "mouth_open_hold", "non_command"):
            pipeline.reset()
            verdicts = run_clip(pipeline, generate_command(rng, command, seconds=5.0).values)
            print(command, [v.to_dict() for v in verdicts])
        for kind in ("involuntary", "possible_spasm", "possible_seizure_like"):
            pipeline.reset()
            verdicts = run_clip(pipeline, generate_abnormal(rng, kind, seconds=5.0).values)
            print(kind, [v.to_dict() for v in verdicts])
        return 0
    print("running live; press Ctrl+C to stop")
    try:
        for features in _camera_frames(args.camera, args.seconds):
            verdict = pipeline.push(features)
            if verdict is not None:
                print(_json(verdict.to_dict()))
                if args.reason:
                    from .reasoning import GeminiReasoner, ReasoningRequest

                    text, used = GeminiReasoner().reason(
                        ReasoningRequest("summarize", pipeline.event_payload())
                    )
                    print(("[gemini] " if used else "[offline] ") + text)
    except KeyboardInterrupt:
        pass
    return 0


def cmd_models(args: argparse.Namespace) -> int:
    from .extractor import default_model_dir, fetch_models

    if args.action == "fetch":
        paths = fetch_models(Path(args.dir) if args.dir else None)
        for name, path in paths.items():
            print(f"{name}: {path}")
        return 0
    print(default_model_dir())
    return 0


def cmd_reason(args: argparse.Namespace) -> int:
    from .reasoning import GeminiReasoner, ReasoningRequest

    payload = json.loads(Path(args.payload).read_text(encoding="utf-8"))
    text, used = GeminiReasoner(api_key=args.api_key, model=args.model).reason(
        ReasoningRequest(args.task, payload, caregiver_question=args.question)
    )
    print(("[gemini] " if used else "[offline] ") + text)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="neurobridge-intent",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    train = sub.add_parser("train", help="train bootstrap models and export a bundle")
    train.add_argument("--output", default="models/intent_bundle_v1")
    train.add_argument("--per-class", type=int, default=60)
    train.add_argument("--seed", type=int, default=7)
    train.add_argument("--epochs", type=int, default=30)
    train.add_argument(
        "--algorithm", choices=["random_forest", "xgboost", "svm"], default="random_forest"
    )
    train.add_argument("--no-temporal", action="store_true")
    train.add_argument("--no-onnx", action="store_true")
    train.add_argument("--verbose", action="store_true")
    train.set_defaults(func=cmd_train)

    export_app = sub.add_parser(
        "export-app", help="copy the JSON runtime files into the Flutter asset folder"
    )
    export_app.add_argument("--bundle", default="models/intent_bundle_v1")
    export_app.add_argument("--output", default="../../apps/mobile/assets/models/intent_bundle_v1")
    export_app.set_defaults(func=cmd_export_app)

    verify = sub.add_parser("verify", help="check a bundle's checksums and schema")
    verify.add_argument("bundle")
    verify.set_defaults(func=cmd_verify)

    calibrate = sub.add_parser("calibrate", help="record the five calibration phases")
    calibrate.add_argument("--patient-id", required=True)
    calibrate.add_argument("--output", default="patient_profile.json")
    calibrate.add_argument("--seconds", type=float, default=CALIBRATION_PHASE_SECONDS)
    calibrate.add_argument("--camera", type=int, default=0)
    calibrate.add_argument("--synthetic", action="store_true")
    calibrate.add_argument("--seed", type=int, default=1)
    calibrate.set_defaults(func=cmd_calibrate)

    run = sub.add_parser("run", help="run the pipeline on a camera or synthetic clips")
    run.add_argument("--bundle", required=True)
    run.add_argument("--profile")
    run.add_argument("--camera", type=int, default=0)
    run.add_argument("--seconds", type=float, default=3600)
    run.add_argument("--synthetic", action="store_true")
    run.add_argument("--seed", type=int, default=3)
    run.add_argument("--reason", action="store_true", help="also call the optional Gemini layer")
    run.set_defaults(func=cmd_run)

    models = sub.add_parser("models", help="manage MediaPipe task files")
    models.add_argument("action", choices=["fetch", "dir"])
    models.add_argument("--dir")
    models.set_defaults(func=cmd_models)

    reason = sub.add_parser(
        "reason", help="run the optional Gemini reasoning layer on a structured event"
    )
    reason.add_argument("--payload", required=True)
    reason.add_argument("--task", default="summarize")
    reason.add_argument("--question")
    reason.add_argument("--api-key")
    reason.add_argument("--model", default="gemini-2.5-flash")
    reason.set_defaults(func=cmd_reason)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
