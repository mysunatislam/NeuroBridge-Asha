"""Optional TensorFlow/Keras training and TensorFlow.js export support."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
from numpy.typing import ArrayLike, NDArray

from .features import ENGINEERED_FEATURE_LENGTH, SEQUENCE_LENGTH

FloatArray = NDArray[np.float64]


class OptionalDependencyError(RuntimeError):
    """Raised when an explicitly requested optional ML backend is unavailable."""


def _tensorflow() -> Any:
    try:
        import tensorflow as tf
    except ImportError as exc:
        raise OptionalDependencyError(
            "TensorFlow support is not installed; install fingerspeak-ml[tensorflow]"
        ) from exc
    return tf


@dataclass(frozen=True, slots=True)
class TrainingOutcome:
    model: Any
    history: dict[str, tuple[float, ...]]


def build_bigru_model(
    num_classes: int,
    *,
    sequence_length: int = SEQUENCE_LENGTH,
    feature_length: int = ENGINEERED_FEATURE_LENGTH,
) -> Any:
    """Build the browser prototype's BiGRU(24) architecture in Keras."""

    if isinstance(num_classes, bool) or not isinstance(num_classes, int) or num_classes < 2:
        raise ValueError("num_classes must be an integer of at least two")
    tf = _tensorflow()
    model = tf.keras.Sequential(
        [
            tf.keras.Input(shape=(sequence_length, feature_length)),
            tf.keras.layers.Bidirectional(
                tf.keras.layers.GRU(24, return_sequences=False), merge_mode="concat"
            ),
            tf.keras.layers.Dropout(0.3),
            tf.keras.layers.Dense(20, activation="relu"),
            tf.keras.layers.Dense(num_classes, activation="softmax"),
        ]
    )
    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=0.008),
        loss="categorical_crossentropy",
        metrics=["accuracy"],
    )
    return model


def _training_arrays(
    features: ArrayLike,
    labels: ArrayLike,
    num_classes: int,
    *,
    allow_empty: bool = False,
) -> tuple[NDArray[np.float32], NDArray[np.int64]]:
    x = np.asarray(features, dtype=np.float32)
    y = np.asarray(labels)
    expected_tail = (SEQUENCE_LENGTH, ENGINEERED_FEATURE_LENGTH)
    if x.ndim != 3 or x.shape[1:] != expected_tail:
        raise ValueError(
            f"features must have shape (samples, {expected_tail[0]}, {expected_tail[1]})"
        )
    if y.ndim != 1 or y.shape[0] != x.shape[0] or not np.issubdtype(y.dtype, np.integer):
        raise ValueError("labels must be a one-dimensional integer array matching features")
    y = y.astype(np.int64, copy=False)
    if not allow_empty and x.shape[0] == 0:
        raise ValueError("training data must not be empty")
    if not np.all(np.isfinite(x)):
        raise ValueError("features must contain only finite values")
    if y.size and (y.min() < 0 or y.max() >= num_classes):
        raise ValueError("label is outside the configured class range")
    return x, y


def train_bigru(
    train_x: ArrayLike,
    train_y: ArrayLike,
    num_classes: int,
    *,
    validation_x: ArrayLike | None = None,
    validation_y: ArrayLike | None = None,
    epochs: int = 150,
    patience: int = 14,
    batch_size: int = 24,
    seed: int = 0,
    verbose: int = 0,
) -> TrainingOutcome:
    """Train with early stopping and best-weight restoration when validation exists."""

    if epochs <= 0 or patience <= 0 or batch_size <= 0:
        raise ValueError("epochs, patience, and batch_size must be positive")
    tf = _tensorflow()
    x_train, y_train = _training_arrays(train_x, train_y, num_classes)
    tf.keras.utils.set_random_seed(seed)
    model = build_bigru_model(num_classes)
    fit_arguments: dict[str, Any] = {
        "x": x_train,
        "y": tf.one_hot(y_train, depth=num_classes),
        "epochs": epochs,
        "batch_size": min(batch_size, x_train.shape[0]),
        "shuffle": True,
        "verbose": verbose,
    }
    callbacks: list[Any] = []
    if validation_x is not None or validation_y is not None:
        if validation_x is None or validation_y is None:
            raise ValueError("validation_x and validation_y must be supplied together")
        x_validation, y_validation = _training_arrays(
            validation_x, validation_y, num_classes, allow_empty=True
        )
        if x_validation.shape[0]:
            fit_arguments["validation_data"] = (
                x_validation,
                tf.one_hot(y_validation, depth=num_classes),
            )
            callbacks.append(
                tf.keras.callbacks.EarlyStopping(
                    monitor="val_loss",
                    patience=patience,
                    min_delta=1e-4,
                    restore_best_weights=True,
                )
            )
    if callbacks:
        fit_arguments["callbacks"] = callbacks
    history = model.fit(**fit_arguments)
    normalized_history = {
        key: tuple(float(value) for value in values)
        for key, values in history.history.items()
    }
    return TrainingOutcome(model=model, history=normalized_history)


def predict_probabilities(model: Any, features: ArrayLike) -> FloatArray:
    x = np.asarray(features, dtype=np.float32)
    if x.ndim != 3 or x.shape[1:] != (SEQUENCE_LENGTH, ENGINEERED_FEATURE_LENGTH):
        raise ValueError(
            f"features must have shape (samples, {SEQUENCE_LENGTH}, {ENGINEERED_FEATURE_LENGTH})"
        )
    probabilities = np.asarray(model.predict(x, verbose=0), dtype=np.float64)
    if probabilities.ndim != 2 or probabilities.shape[0] != x.shape[0]:
        raise ValueError("model produced an unexpected prediction shape")
    if not np.all(np.isfinite(probabilities)):
        raise ValueError("model produced non-finite probabilities")
    return probabilities


def load_keras_model(path: str | Path) -> Any:
    tf = _tensorflow()
    return tf.keras.models.load_model(Path(path))


def export_keras_model_to_tfjs(model: Any, output_directory: str | Path) -> Path:
    """Export a Keras model as a TensorFlow.js LayersModel directory."""

    _tensorflow()  # Produce the clearer dependency error before importing tensorflowjs.
    try:
        import tensorflowjs as tfjs
    except ImportError as exc:
        raise OptionalDependencyError(
            "TensorFlow.js export support is not installed; install fingerspeak-ml[tensorflow]"
        ) from exc
    destination = Path(output_directory)
    destination.mkdir(parents=True, exist_ok=True)
    tfjs.converters.save_keras_model(model, str(destination))
    model_json = destination / "model.json"
    if not model_json.is_file():
        raise RuntimeError("TensorFlow.js converter did not produce model.json")
    return model_json
