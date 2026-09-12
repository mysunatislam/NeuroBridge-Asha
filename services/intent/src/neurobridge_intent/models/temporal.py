"""Phase 2: temporal intelligence over 2-5 second movement sequences.

Architecture (``TemporalModelSpec``): a small temporal CNN

    input (T, C) -> Conv1D(k=5) -> ReLU -> Conv1D(k=5, stride 2) -> ReLU
                 -> Conv1D(k=3) -> ReLU -> global average + max pooling
                 -> Dense -> ReLU -> Dense(softmax over command classes)

Training uses Keras (optional ``tensorflow`` extra). Inference uses the pure-NumPy
``TemporalRuntime`` from the exported JSON weights, which is also the reference for
the Dart port. The same weights are exported to TensorFlow Lite for Android and to
ONNX (via tf2onnx when available) for ONNX Runtime Mobile.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np
from numpy.typing import ArrayLike, NDArray

from ..schema import COMMAND_CLASSES, FRAME_FEATURE_COUNT, SEQUENCE_FRAMES

FloatArray = NDArray[np.float64]


@dataclass(slots=True)
class TemporalModelSpec:
    sequence_frames: int = SEQUENCE_FRAMES
    channels: int = FRAME_FEATURE_COUNT
    classes: list[str] = field(default_factory=lambda: list(COMMAND_CLASSES))
    conv_filters: tuple[int, int, int] = (32, 48, 48)
    dense_units: int = 48
    dropout: float = 0.2


def _conv1d_same(x: FloatArray, kernel: FloatArray, bias: FloatArray, stride: int) -> FloatArray:
    """NumPy Conv1D with 'same' padding matching Keras semantics. x: (T, Cin)."""

    k, cin, cout = kernel.shape
    t = x.shape[0]
    out_len = -(-t // stride)  # ceil
    pad_total = max((out_len - 1) * stride + k - t, 0)
    pad_left = pad_total // 2
    padded = np.zeros((t + pad_total, cin), dtype=np.float64)
    padded[pad_left : pad_left + t] = x
    out = np.empty((out_len, cout), dtype=np.float64)
    for i in range(out_len):
        start = i * stride
        window = padded[start : start + k]  # (k, cin)
        out[i] = np.tensordot(window, kernel, axes=([0, 1], [0, 1])) + bias
    return out


def _relu(x: FloatArray) -> FloatArray:
    return np.maximum(x, 0.0)


def _softmax(x: FloatArray) -> FloatArray:
    z = x - x.max()
    e = np.exp(z)
    return e / e.sum()


class TemporalRuntime:
    """Evaluate exported JSON weights. Input sequences must already be normalised."""

    def __init__(self, spec: dict[str, Any]) -> None:
        if spec.get("type") != "temporal_cnn":
            raise ValueError("spec is not a temporal_cnn export")
        self.classes: list[str] = list(spec["classes"])
        self.sequence_frames = int(spec["sequence_frames"])
        self.channels = int(spec["channels"])
        self.layers = spec["layers"]
        self._weights = {
            layer["name"]: {k: np.asarray(v, dtype=np.float64) for k, v in layer["weights"].items()}
            for layer in self.layers
        }
        self.norm_mean = np.asarray(spec["normalizer"]["mean"], dtype=np.float64)
        self.norm_std = np.asarray(spec["normalizer"]["std"], dtype=np.float64)

    def predict_proba(self, sequence: ArrayLike, *, normalized: bool = False) -> FloatArray:
        x = np.asarray(sequence, dtype=np.float64)
        if x.shape != (self.sequence_frames, self.channels):
            raise ValueError(f"expected ({self.sequence_frames}, {self.channels}), got {x.shape}")
        if not normalized:
            x = (x - self.norm_mean) / self.norm_std
        x = np.clip(x, -8.0, 8.0)
        for layer in self.layers:
            w = self._weights[layer["name"]]
            kind = layer["kind"]
            if kind == "conv1d":
                x = _relu(_conv1d_same(x, w["kernel"], w["bias"], int(layer["stride"])))
            elif kind == "global_pool":
                x = np.concatenate([x.mean(axis=0), x.max(axis=0)])
            elif kind == "dense":
                x = x @ w["kernel"] + w["bias"]
                if layer.get("activation") == "relu":
                    x = _relu(x)
            else:  # pragma: no cover - schema guard
                raise ValueError(f"unknown layer kind {kind}")
        return _softmax(x)

    def predict(self, sequence: ArrayLike, *, normalized: bool = False) -> tuple[str, float]:
        proba = self.predict_proba(sequence, normalized=normalized)
        index = int(np.argmax(proba))
        return self.classes[index], float(proba[index])


def build_keras_model(spec: TemporalModelSpec) -> Any:
    try:
        import tensorflow as tf
    except ModuleNotFoundError as exc:  # pragma: no cover - optional
        raise RuntimeError("install the 'tensorflow' extra to train the temporal model") from exc
    layers = tf.keras.layers
    f1, f2, f3 = spec.conv_filters
    inputs = tf.keras.Input(shape=(spec.sequence_frames, spec.channels), name="sequence")
    x = layers.Conv1D(f1, 5, padding="same", activation="relu", name="conv1")(inputs)
    x = layers.Conv1D(f2, 5, strides=2, padding="same", activation="relu", name="conv2")(x)
    x = layers.Conv1D(f3, 3, padding="same", activation="relu", name="conv3")(x)
    avg = layers.GlobalAveragePooling1D(name="gap")(x)
    mx = layers.GlobalMaxPooling1D(name="gmp")(x)
    x = layers.Concatenate(name="pool")([avg, mx])
    x = layers.Dropout(spec.dropout)(x)
    x = layers.Dense(spec.dense_units, activation="relu", name="dense1")(x)
    outputs = layers.Dense(len(spec.classes), activation="softmax", name="logits")(x)
    model = tf.keras.Model(inputs, outputs, name="neurobridge_temporal_cnn")
    model.compile(
        optimizer=tf.keras.optimizers.Adam(1e-3),
        loss="sparse_categorical_crossentropy",
        metrics=["accuracy"],
    )
    return model


def train_temporal(
    sequences: ArrayLike,
    labels: ArrayLike,
    *,
    spec: TemporalModelSpec | None = None,
    normalizer: tuple[FloatArray, FloatArray] | None = None,
    epochs: int = 25,
    batch_size: int = 32,
    validation_split: float = 0.15,
    seed: int = 7,
    verbose: int = 0,
) -> tuple[Any, dict[str, Any]]:
    """Train the Keras model; returns (model, exported JSON spec)."""

    try:
        import tensorflow as tf
    except ImportError as exc:  # pragma: no cover - optional
        raise RuntimeError("install the 'tensorflow' extra to train the temporal model") from exc

    spec = spec or TemporalModelSpec()
    X = np.asarray(sequences, dtype=np.float32)
    y = np.asarray([spec.classes.index(label) for label in labels], dtype=np.int64)
    if X.ndim != 3 or X.shape[1:] != (spec.sequence_frames, spec.channels):
        raise ValueError("sequences must be (n, sequence_frames, channels)")
    if normalizer is None:
        flat = X.reshape(-1, spec.channels)
        mean, std = flat.mean(axis=0), np.maximum(flat.std(axis=0), 1e-3)
    else:
        mean, std = (np.asarray(v, dtype=np.float64) for v in normalizer)
    Xn = np.clip((X - mean) / std, -8.0, 8.0).astype(np.float32)
    tf.keras.utils.set_random_seed(seed)
    model = build_keras_model(spec)
    callbacks = [
        tf.keras.callbacks.EarlyStopping(patience=6, restore_best_weights=True, monitor="val_loss")
    ]
    model.fit(
        Xn,
        y,
        epochs=epochs,
        batch_size=batch_size,
        validation_split=validation_split,
        callbacks=callbacks,
        verbose=verbose,
        shuffle=True,
    )
    exported = export_keras_json(model, spec, mean, std)
    return model, exported


def export_keras_json(
    model: Any, spec: TemporalModelSpec, mean: FloatArray, std: FloatArray
) -> dict[str, Any]:
    layers: list[dict[str, Any]] = []
    for name, stride in (("conv1", 1), ("conv2", 2), ("conv3", 1)):
        kernel, bias = model.get_layer(name).get_weights()
        layers.append(
            {
                "name": name,
                "kind": "conv1d",
                "stride": stride,
                "weights": {"kernel": kernel.tolist(), "bias": bias.tolist()},
            }
        )
    layers.append({"name": "pool", "kind": "global_pool", "weights": {}})
    for name, activation in (("dense1", "relu"), ("logits", "linear")):
        kernel, bias = model.get_layer(name).get_weights()
        layers.append(
            {
                "name": name,
                "kind": "dense",
                "activation": activation,
                "weights": {"kernel": kernel.tolist(), "bias": bias.tolist()},
            }
        )
    return {
        "type": "temporal_cnn",
        "classes": list(spec.classes),
        "sequence_frames": spec.sequence_frames,
        "channels": spec.channels,
        "normalizer": {"mean": np.asarray(mean).tolist(), "std": np.asarray(std).tolist()},
        "layers": layers,
    }


def export_tflite(model: Any, path: str | Path) -> Path:
    import tensorflow as tf

    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS]
    data = converter.convert()
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    return target


def export_onnx(model: Any, path: str | Path) -> Path | None:
    """Best-effort ONNX export through tf2onnx; returns None when unavailable."""

    try:
        import tensorflow as tf
        import tf2onnx  # type: ignore[import-not-found]
    except ModuleNotFoundError:
        return None
    spec = (
        tf.TensorSpec(
            (None, model.input_shape[1], model.input_shape[2]), tf.float32, name="sequence"
        ),
    )
    onnx_model, _ = tf2onnx.convert.from_keras(model, input_signature=spec, opset=13)
    target = Path(path)
    target.write_bytes(onnx_model.SerializeToString())
    return target


def random_runtime(spec: TemporalModelSpec | None = None, *, seed: int = 0) -> TemporalRuntime:
    """Randomly initialised runtime for tests that must not depend on TensorFlow."""

    spec = spec or TemporalModelSpec()
    rng = np.random.default_rng(seed)
    f1, f2, f3 = spec.conv_filters

    def conv(name: str, k: int, cin: int, cout: int, stride: int) -> dict[str, Any]:
        return {
            "name": name,
            "kind": "conv1d",
            "stride": stride,
            "weights": {
                "kernel": (rng.normal(0, 0.2, (k, cin, cout))).tolist(),
                "bias": np.zeros(cout).tolist(),
            },
        }

    def dense(name: str, cin: int, cout: int, activation: str) -> dict[str, Any]:
        return {
            "name": name,
            "kind": "dense",
            "activation": activation,
            "weights": {
                "kernel": (rng.normal(0, 0.2, (cin, cout))).tolist(),
                "bias": np.zeros(cout).tolist(),
            },
        }

    layers = [
        conv("conv1", 5, spec.channels, f1, 1),
        conv("conv2", 5, f1, f2, 2),
        conv("conv3", 3, f2, f3, 1),
        {"name": "pool", "kind": "global_pool", "weights": {}},
        dense("dense1", 2 * f3, spec.dense_units, "relu"),
        dense("logits", spec.dense_units, len(spec.classes), "linear"),
    ]
    return TemporalRuntime(
        {
            "type": "temporal_cnn",
            "classes": spec.classes,
            "sequence_frames": spec.sequence_frames,
            "channels": spec.channels,
            "normalizer": {
                "mean": np.zeros(spec.channels).tolist(),
                "std": np.ones(spec.channels).tolist(),
            },
            "layers": layers,
        }
    )


def load_runtime(path: str | Path) -> TemporalRuntime:
    return TemporalRuntime(json.loads(Path(path).read_text(encoding="utf-8")))
