"""Train on (calibration + synthetic) data and export a deployable model bundle.

Bundle layout (``models/intent_bundle_v1/``)::

    manifest.json        schema versions, sha256 of every file, training metrics
    intent_rf.json       Phase 1 forest + OOD gate (Dart / NumPy runtime)
    temporal_cnn.json    Phase 2 weights (Dart / NumPy runtime)
    temporal_cnn.tflite  Phase 2 for TensorFlow Lite on Android (when TF is installed)
    temporal_cnn.onnx    Phase 2 for ONNX Runtime Mobile (when tf2onnx is installed)
    abnormal_rf.json     Phase 3 forest + rule floor
    intent_rf.onnx       Phase 1 for ONNX Runtime Mobile (when skl2onnx is installed)
    abnormal_rf.onnx     Phase 3 for ONNX Runtime Mobile (when skl2onnx is installed)

The Flutter app ships the JSON files as assets; Android-native integrations can pick
the ``.tflite`` / ``.onnx`` files instead. Every file is checksummed in the manifest.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import numpy as np

from .features.window import window_features
from .models.abnormal import AbnormalMovementDetector
from .models.intent_classifier import IntentClassifier
from .models.temporal import TemporalModelSpec
from .schema import (
    BUNDLE_SCHEMA_VERSION,
    COMMAND_CLASSES,
    FRAME_FEATURES,
    FRAME_SCHEMA_VERSION,
    SEQUENCE_FRAMES,
    WINDOW_FEATURES,
    WINDOW_FRAMES,
    WINDOW_SCHEMA_VERSION,
    AbnormalClass,
    CommandClass,
)
from .synthetic import SyntheticClip, generate_dataset


@dataclass(slots=True)
class TrainingData:
    window_X: np.ndarray
    intentional: np.ndarray
    abnormal: np.ndarray
    sequences: np.ndarray
    commands: np.ndarray


def clips_to_training_data(
    clips: list[SyntheticClip], *, open_ear: float | None = None
) -> TrainingData:
    windows, intentional, abnormal, sequences, commands = [], [], [], [], []
    for clip in clips:
        values = clip.values
        if values.shape[0] < WINDOW_FRAMES:
            continue
        # Window features from the last WINDOW_FRAMES (where the pattern has completed).
        windows.append(window_features(values[-WINDOW_FRAMES:], open_ear=open_ear))
        intentional.append(bool(clip.intentional))
        abnormal.append(str(clip.abnormal))
        seq = values[-SEQUENCE_FRAMES:]
        if seq.shape[0] < SEQUENCE_FRAMES:
            seq = np.concatenate([np.repeat(seq[:1], SEQUENCE_FRAMES - seq.shape[0], axis=0), seq])
        sequences.append(seq)
        commands.append(str(clip.command))
    return TrainingData(
        np.stack(windows),
        np.asarray(intentional),
        np.asarray(abnormal),
        np.stack(sequences),
        np.asarray(commands),
    )


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    digest.update(path.read_bytes())
    return digest.hexdigest()


def _split(n: int, seed: int, fraction: float = 0.2) -> tuple[np.ndarray, np.ndarray]:
    rng = np.random.default_rng(seed)
    index = rng.permutation(n)
    cut = int(n * (1 - fraction))
    return index[:cut], index[cut:]


def train_and_export(
    output_dir: str | Path,
    *,
    clips: list[SyntheticClip] | None = None,
    per_class: int = 60,
    seed: int = 7,
    epochs: int = 30,
    algorithm: str = "random_forest",
    with_temporal: bool = True,
    with_onnx: bool = True,
    verbose: bool = False,
) -> dict[str, Any]:
    """Train all three models and write the bundle. Returns the manifest."""

    output = Path(output_dir)
    output.mkdir(parents=True, exist_ok=True)
    clips = clips if clips is not None else generate_dataset(seed=seed, per_class=per_class)
    data = clips_to_training_data(clips)
    train_idx, test_idx = _split(len(data.window_X), seed)
    metrics: dict[str, Any] = {"samples": int(len(data.window_X))}
    files: dict[str, str] = {}

    # Phase 1 --------------------------------------------------------------------
    intent = IntentClassifier(algorithm=algorithm, random_state=seed)
    intent.fit(data.window_X[train_idx], data.intentional[train_idx])
    metrics["intent_accuracy"] = intent.accuracy(
        data.window_X[test_idx], data.intentional[test_idx]
    )
    if algorithm == "random_forest":
        (output / "intent_rf.json").write_text(json.dumps(intent.export_json()), encoding="utf-8")
        files["intent_json"] = "intent_rf.json"
    if with_onnx:
        try:
            intent.export_onnx(str(output / "intent_rf.onnx"))
            files["intent_onnx"] = "intent_rf.onnx"
        except RuntimeError as exc:
            metrics["intent_onnx_skipped"] = str(exc)

    # Phase 3 --------------------------------------------------------------------
    abnormal = AbnormalMovementDetector(random_state=seed)
    abnormal.fit(data.window_X[train_idx], data.abnormal[train_idx])
    metrics["abnormal_accuracy"] = abnormal.accuracy(
        data.window_X[test_idx], data.abnormal[test_idx]
    )
    (output / "abnormal_rf.json").write_text(json.dumps(abnormal.export_json()), encoding="utf-8")
    files["abnormal_json"] = "abnormal_rf.json"
    if with_onnx:
        try:
            from skl2onnx import convert_sklearn
            from skl2onnx.common.data_types import FloatTensorType

            onx = convert_sklearn(
                abnormal.model,
                initial_types=[("input", FloatTensorType([None, len(WINDOW_FEATURES)]))],
                options={id(abnormal.model): {"zipmap": False}},
            )
            (output / "abnormal_rf.onnx").write_bytes(onx.SerializeToString())
            files["abnormal_onnx"] = "abnormal_rf.onnx"
        except ModuleNotFoundError as exc:
            metrics["abnormal_onnx_skipped"] = str(exc)

    # Phase 2 --------------------------------------------------------------------
    if with_temporal:
        try:
            from .models.temporal import export_onnx, export_tflite, train_temporal

            spec = TemporalModelSpec()
            model, exported = train_temporal(
                data.sequences[train_idx],
                data.commands[train_idx],
                spec=spec,
                epochs=epochs,
                seed=seed,
                verbose=1 if verbose else 0,
            )
            from .models.temporal import TemporalRuntime

            runtime = TemporalRuntime(exported)
            predicted = [runtime.predict(seq)[0] for seq in data.sequences[test_idx]]
            metrics["temporal_accuracy"] = float(
                np.mean(np.asarray(predicted) == data.commands[test_idx])
            )
            (output / "temporal_cnn.json").write_text(json.dumps(exported), encoding="utf-8")
            files["temporal_json"] = "temporal_cnn.json"
            export_tflite(model, output / "temporal_cnn.tflite")
            files["temporal_tflite"] = "temporal_cnn.tflite"
            onnx_path = export_onnx(model, output / "temporal_cnn.onnx")
            if onnx_path is not None:
                files["temporal_onnx"] = "temporal_cnn.onnx"
            # Parity: Keras vs NumPy runtime on the test set.
            keras_proba = model.predict(
                np.clip(
                    (data.sequences[test_idx] - np.asarray(exported["normalizer"]["mean"]))
                    / np.asarray(exported["normalizer"]["std"]),
                    -8,
                    8,
                ).astype(np.float32),
                verbose=0,
            )
            numpy_proba = np.stack([runtime.predict_proba(seq) for seq in data.sequences[test_idx]])
            metrics["temporal_runtime_max_abs_diff"] = float(
                np.max(np.abs(keras_proba - numpy_proba))
            )
        except (RuntimeError, ImportError) as exc:
            metrics["temporal_skipped"] = f"{type(exc).__name__}: {exc}"
            _write_fallback_temporal(output, files, data, seed)
    else:
        _write_fallback_temporal(output, files, data, seed)

    manifest = {
        "schema_version": BUNDLE_SCHEMA_VERSION,
        "frame_schema": FRAME_SCHEMA_VERSION,
        "window_schema": WINDOW_SCHEMA_VERSION,
        "created_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "frame_features": list(FRAME_FEATURES),
        "window_features": list(WINDOW_FEATURES),
        "command_classes": list(COMMAND_CLASSES),
        "abnormal_classes": [c.value for c in AbnormalClass],
        "window_frames": WINDOW_FRAMES,
        "sequence_frames": SEQUENCE_FRAMES,
        "training": {
            "algorithm": algorithm,
            "per_class": per_class,
            "seed": seed,
            "source": "synthetic+calibration",
        },
        "metrics": metrics,
        "files": files,
        "checksums": {name: _sha256(output / name) for name in files.values()},
        "safety": {
            "note": "Bootstrap models trained on physiologically-motivated synthetic data "
            "plus calibration recordings. "
            "They gate commands; they do not diagnose. Validate per patient before care use.",
        },
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return manifest


def _write_fallback_temporal(
    output: Path, files: dict[str, str], data: TrainingData, seed: int
) -> None:
    """Prototype-based temporal model used when TensorFlow is unavailable.

    It is exported in the same ``temporal_cnn`` JSON format by fitting a single
    dense layer on pooled sequence statistics through least squares, so the runtime
    contract stays identical. Accuracy is lower than the CNN; the manifest says so.
    """

    from .models.temporal import TemporalModelSpec

    spec = TemporalModelSpec(conv_filters=(1, 1, 1), dense_units=8)
    flat = data.sequences.reshape(-1, spec.channels)
    mean, std = flat.mean(axis=0), np.maximum(flat.std(axis=0), 1e-3)
    normalized = np.clip((data.sequences - mean) / std, -8, 8)
    # Identity-like convs (single channel = mean of inputs) then a linear head on pooled stats.
    k1 = np.zeros((5, spec.channels, 1))
    k1[2, :, 0] = 1.0 / spec.channels
    k2 = np.zeros((5, 1, 1))
    k2[2, 0, 0] = 1.0
    k3 = np.zeros((3, 1, 1))
    k3[1, 0, 0] = 1.0
    # Pooled features are (mean, max) of the per-frame channel mean; fit logits by least squares.
    pooled = np.stack(
        [
            np.concatenate(
                [
                    np.mean(s.mean(axis=1, keepdims=True), axis=0),
                    np.max(s.mean(axis=1, keepdims=True), axis=0),
                ]
            )
            for s in normalized
        ]
    )
    one_hot = np.zeros((len(data.commands), len(spec.classes)))
    for i, label in enumerate(data.commands):
        one_hot[i, spec.classes.index(label)] = 1.0
    design = np.concatenate([pooled, np.ones((len(pooled), 1))], axis=1)
    coef, *_ = np.linalg.lstsq(design, one_hot * 4.0, rcond=None)
    dense1_kernel = np.concatenate([np.eye(2), np.zeros((2, spec.dense_units - 2))], axis=1)
    logits_kernel = np.zeros((spec.dense_units, len(spec.classes)))
    logits_kernel[:2] = coef[:2]
    exported = {
        "type": "temporal_cnn",
        "classes": spec.classes,
        "sequence_frames": spec.sequence_frames,
        "channels": spec.channels,
        "normalizer": {"mean": mean.tolist(), "std": std.tolist()},
        "layers": [
            {
                "name": "conv1",
                "kind": "conv1d",
                "stride": 1,
                "weights": {"kernel": k1.tolist(), "bias": [0.0]},
            },
            {
                "name": "conv2",
                "kind": "conv1d",
                "stride": 2,
                "weights": {"kernel": k2.tolist(), "bias": [0.0]},
            },
            {
                "name": "conv3",
                "kind": "conv1d",
                "stride": 1,
                "weights": {"kernel": k3.tolist(), "bias": [0.0]},
            },
            {"name": "pool", "kind": "global_pool", "weights": {}},
            {
                "name": "dense1",
                "kind": "dense",
                "activation": "relu",
                "weights": {"kernel": dense1_kernel.tolist(), "bias": [8.0] * spec.dense_units},
            },
            {
                "name": "logits",
                "kind": "dense",
                "activation": "linear",
                "weights": {
                    "kernel": logits_kernel.tolist(),
                    "bias": (coef[2] - 8.0 * coef[:2].sum(axis=0)).tolist(),
                },
            },
        ],
        "note": "fallback linear temporal model (TensorFlow unavailable at export time)",
    }
    (output / "temporal_cnn.json").write_text(json.dumps(exported), encoding="utf-8")
    files["temporal_json"] = "temporal_cnn.json"


def verify_bundle(directory: str | Path) -> list[str]:
    """Return a list of problems (empty when the bundle is intact)."""

    root = Path(directory)
    problems: list[str] = []
    manifest_path = root / "manifest.json"
    if not manifest_path.exists():
        return ["manifest.json is missing"]
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema_version") != BUNDLE_SCHEMA_VERSION:
        problems.append("schema_version mismatch")
    for name, digest in manifest.get("checksums", {}).items():
        path = root / name
        if not path.exists():
            problems.append(f"{name} is missing")
        elif _sha256(path) != digest:
            problems.append(f"{name} checksum mismatch")
    for key in ("intent_json", "temporal_json", "abnormal_json"):
        if key not in manifest.get("files", {}):
            problems.append(f"{key} not exported")
    return problems


__all__ = [
    "TrainingData",
    "clips_to_training_data",
    "train_and_export",
    "verify_bundle",
    "CommandClass",
]
