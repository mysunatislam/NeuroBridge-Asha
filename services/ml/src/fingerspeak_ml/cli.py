"""Command-line entry point for validation, experiments, and bundle export."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

import numpy as np

from .bundle import write_model_bundle
from .classifiers import DTWKNNClassifier, OODDetector, PrototypeClassifier
from .dataset import all_sequences_by_class, session_aware_split
from .evaluation import evaluate_classifier, evaluate_predictions
from .schema import ProfileValidationError, load_profile
from .tensorflow_backend import (
    OptionalDependencyError,
    load_keras_model,
    predict_probabilities,
    train_bigru,
)


def _json(value: Any) -> str:
    return json.dumps(value, indent=2, sort_keys=True, allow_nan=False)


def _fit_baselines(sequences_by_class: tuple[tuple[np.ndarray, ...], ...]):
    dtw = DTWKNNClassifier().fit(sequences_by_class)
    prototype = PrototypeClassifier().fit(sequences_by_class)
    ood = OODDetector().fit(sequences_by_class)
    return dtw, prototype, ood


def _evaluation_payload(profile_path: Path, seed: int) -> tuple[Any, Any, dict[str, Any]]:
    profile = load_profile(profile_path, require_trainable=True)
    split = session_aware_split(profile, seed=seed)
    if not split.has_validation:
        raise ValueError(
            "profile has no validation samples; record at least four samples per class "
            "or use two sessions"
        )
    dtw, prototype, _ = _fit_baselines(split.train_sequences_by_class)
    validation_kind = "independent-session" if split.all_session_based else "same-session"
    results = {
        "validation_kind": validation_kind,
        "held_out_sessions": list(split.held_out_sessions),
        "dtw": evaluate_classifier(dtw, split.validation_sequences_by_class).to_dict(
            profile.class_names
        ),
        "prototype": evaluate_classifier(
            prototype, split.validation_sequences_by_class
        ).to_dict(profile.class_names),
    }
    return profile, split, results


def _command_validate(arguments: argparse.Namespace) -> int:
    profile = load_profile(arguments.profile, require_trainable=arguments.trainable)
    summary = {
        "valid": True,
        "version": profile.version,
        "gestures": len(profile.gestures),
        "classes": list(profile.class_names),
        "samples": sum(len(gesture.samples) for gesture in profile.gestures),
        "sessions": sorted(
            {sample.session for gesture in profile.gestures for sample in gesture.samples}
        ),
    }
    print(_json(summary))
    return 0


def _command_evaluate(arguments: argparse.Namespace) -> int:
    profile, split, results = _evaluation_payload(arguments.profile, arguments.seed)
    if arguments.model != "both":
        results = {
            "validation_kind": results["validation_kind"],
            "held_out_sessions": results["held_out_sessions"],
            arguments.model: results[arguments.model],
        }
    if arguments.tensorflow_model:
        model = load_keras_model(arguments.tensorflow_model)
        probabilities = predict_probabilities(model, split.validation_x)
        predicted = np.argmax(probabilities, axis=1)
        results["bigru"] = evaluate_predictions(
            split.validation_y, predicted, len(profile.gestures)
        ).to_dict(profile.class_names)
    rendered = _json(results) + "\n"
    if arguments.output:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0


def _command_train(arguments: argparse.Namespace) -> int:
    profile = load_profile(arguments.profile, require_trainable=True)
    split = session_aware_split(profile, seed=arguments.seed)
    metrics: dict[str, Any] = {
        "validation_kind": (
            "independent-session" if split.all_session_based else "same-session"
        )
    }
    if split.has_validation:
        evaluation_dtw, evaluation_prototype, _ = _fit_baselines(
            split.train_sequences_by_class
        )
        metrics["dtw"] = evaluate_classifier(
            evaluation_dtw, split.validation_sequences_by_class
        ).to_dict(profile.class_names)
        metrics["prototype"] = evaluate_classifier(
            evaluation_prototype, split.validation_sequences_by_class
        ).to_dict(profile.class_names)

    keras_model = None
    if arguments.backend == "tensorflow":
        outcome = train_bigru(
            split.train_x,
            split.train_y,
            len(profile.gestures),
            validation_x=split.validation_x,
            validation_y=split.validation_y,
            epochs=arguments.epochs,
            patience=arguments.patience,
            seed=arguments.seed,
            verbose=arguments.verbose,
        )
        keras_model = outcome.model
        metrics["training_history"] = {
            key: list(values) for key, values in outcome.history.items()
        }
        if split.has_validation:
            probabilities = predict_probabilities(keras_model, split.validation_x)
            metrics["bigru"] = evaluate_predictions(
                split.validation_y,
                np.argmax(probabilities, axis=1),
                len(profile.gestures),
            ).to_dict(profile.class_names)

    full_sequences = all_sequences_by_class(profile)
    dtw, prototype, ood = _fit_baselines(full_sequences)
    manifest = write_model_bundle(
        arguments.output,
        profile=profile,
        dtw=dtw,
        prototype=prototype,
        ood=ood,
        metrics=metrics,
        keras_model=keras_model,
        overwrite=arguments.force,
    )
    print(_json({"bundle": str(manifest), "backend": arguments.backend}))
    return 0


def _command_export(arguments: argparse.Namespace) -> int:
    profile = load_profile(arguments.profile, require_trainable=True)
    full_sequences = all_sequences_by_class(profile)
    dtw, prototype, ood = _fit_baselines(full_sequences)
    keras_model = load_keras_model(arguments.keras_model) if arguments.keras_model else None
    manifest = write_model_bundle(
        arguments.output,
        profile=profile,
        dtw=dtw,
        prototype=prototype,
        ood=ood,
        keras_model=keras_model,
        overwrite=arguments.force,
    )
    print(_json({"bundle": str(manifest)}))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="fingerspeak-ml",
        description="FingerSpeak profile validation, model evaluation, training, and export",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate = subparsers.add_parser("validate", help="validate a version-2 profile")
    validate.add_argument("profile", type=Path)
    validate.add_argument(
        "--trainable",
        action="store_true",
        help="also require samples for every class",
    )
    validate.set_defaults(handler=_command_validate)

    evaluate = subparsers.add_parser("evaluate", help="evaluate a held-out profile split")
    evaluate.add_argument("profile", type=Path)
    evaluate.add_argument("--model", choices=("dtw", "prototype", "both"), default="both")
    evaluate.add_argument("--tensorflow-model", type=Path)
    evaluate.add_argument("--seed", type=int, default=0)
    evaluate.add_argument("--output", type=Path)
    evaluate.set_defaults(handler=_command_evaluate)

    train = subparsers.add_parser("train", help="train models and emit a browser model bundle")
    train.add_argument("profile", type=Path)
    train.add_argument("--output", type=Path, required=True)
    train.add_argument("--backend", choices=("baseline", "tensorflow"), default="baseline")
    train.add_argument("--epochs", type=int, default=150)
    train.add_argument("--patience", type=int, default=14)
    train.add_argument("--seed", type=int, default=0)
    train.add_argument("--verbose", type=int, choices=(0, 1, 2), default=0)
    train.add_argument("--force", action="store_true")
    train.set_defaults(handler=_command_train)

    export = subparsers.add_parser(
        "export",
        help="export fitted baselines and an optional Keras model",
    )
    export.add_argument("profile", type=Path)
    export.add_argument("--output", type=Path, required=True)
    export.add_argument("--keras-model", type=Path)
    export.add_argument("--force", action="store_true")
    export.set_defaults(handler=_command_export)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    arguments = parser.parse_args(argv)
    try:
        return int(arguments.handler(arguments))
    except (
        ProfileValidationError,
        OptionalDependencyError,
        FileExistsError,
        OSError,
        ValueError,
    ) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
