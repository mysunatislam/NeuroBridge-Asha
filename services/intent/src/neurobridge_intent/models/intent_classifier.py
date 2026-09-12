"""Phase 1: intentional vs accidental movement on window features.

``IntentClassifier`` wraps one of three lightweight offline learners. Random Forest
is the default because it exports to the portable JSON tree format; XGBoost and SVM
are available for experiments (``--algorithm``). The ``unknown`` class is produced
by a rejection gate, not learned: low margin or an out-of-distribution window is
reported as unknown so downstream never executes on it.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import numpy as np
from numpy.typing import ArrayLike, NDArray

from ..schema import INTENT_CLASSES, WINDOW_FEATURE_COUNT, WINDOW_FEATURES, IntentClass
from .tree_export import TreeEnsembleRuntime, export_forest

FloatArray = NDArray[np.float64]


@dataclass(frozen=True, slots=True)
class IntentPrediction:
    label: str
    p_intentional: float
    p_accidental: float
    margin: float
    in_distribution: bool
    ood_ratio: float

    def to_dict(self) -> dict[str, float | str | bool]:
        return {
            "label": self.label,
            "p_intentional": self.p_intentional,
            "p_accidental": self.p_accidental,
            "margin": self.margin,
            "in_distribution": self.in_distribution,
            "ood_ratio": self.ood_ratio,
        }


class IntentClassifier:
    def __init__(
        self,
        *,
        algorithm: str = "random_forest",
        min_margin: float = 0.25,
        ood_multiplier: float = 3.5,
        n_estimators: int = 120,
        max_depth: int | None = 10,
        random_state: int = 7,
    ) -> None:
        if algorithm not in {"random_forest", "xgboost", "svm"}:
            raise ValueError("algorithm must be random_forest, xgboost or svm")
        self.algorithm = algorithm
        self.min_margin = min_margin
        self.ood_multiplier = ood_multiplier
        self.n_estimators = n_estimators
        self.max_depth = max_depth
        self.random_state = random_state
        self.model: Any | None = None
        self.scaler_mean: FloatArray | None = None
        self.scaler_std: FloatArray | None = None
        self.centroid: FloatArray | None = None
        self.ood_threshold: float = 0.0

    # -- training --------------------------------------------------------------------

    def fit(self, X: ArrayLike, y: ArrayLike) -> IntentClassifier:
        X = np.asarray(X, dtype=np.float64)
        y = np.asarray(y)
        if X.ndim != 2 or X.shape[1] != WINDOW_FEATURE_COUNT:
            raise ValueError(f"X must be (n, {WINDOW_FEATURE_COUNT})")
        labels = np.where(
            y.astype(bool), IntentClass.intentional.value, IntentClass.accidental.value
        )
        self.scaler_mean = X.mean(axis=0)
        self.scaler_std = np.maximum(X.std(axis=0), 1e-6)
        Z = self._scale(X)
        self.centroid = Z.mean(axis=0)
        distances = np.linalg.norm(Z - self.centroid, axis=1)
        self.ood_threshold = float(np.percentile(distances, 99) * self.ood_multiplier / 3.5)

        if self.algorithm == "random_forest":
            from sklearn.ensemble import RandomForestClassifier

            model = RandomForestClassifier(
                n_estimators=self.n_estimators,
                max_depth=self.max_depth,
                min_samples_leaf=2,
                class_weight="balanced",
                random_state=self.random_state,
                n_jobs=1,
            )
            model.fit(X, labels)  # raw features: trees do not need scaling
        elif self.algorithm == "xgboost":
            try:
                from xgboost import XGBClassifier
            except ModuleNotFoundError as exc:  # pragma: no cover - optional
                raise RuntimeError("install the 'xgboost' extra for --algorithm xgboost") from exc
            model = XGBClassifier(
                n_estimators=self.n_estimators,
                max_depth=6,
                learning_rate=0.1,
                subsample=0.9,
                colsample_bytree=0.8,
                random_state=self.random_state,
                n_jobs=1,
            )
            model.fit(X, (labels == IntentClass.intentional.value).astype(int))
        else:
            from sklearn.svm import SVC

            model = SVC(
                C=2.0,
                kernel="rbf",
                probability=True,
                class_weight="balanced",
                random_state=self.random_state,
            )
            model.fit(Z, labels)
        self.model = model
        return self

    def _scale(self, X: FloatArray) -> FloatArray:
        assert self.scaler_mean is not None and self.scaler_std is not None
        return (X - self.scaler_mean) / self.scaler_std

    # -- inference -------------------------------------------------------------------

    def _proba_intentional(self, X: FloatArray) -> FloatArray:
        assert self.model is not None
        if self.algorithm == "random_forest":
            classes = list(self.model.classes_)
            proba = self.model.predict_proba(X)
            return proba[:, classes.index(IntentClass.intentional.value)]
        if self.algorithm == "xgboost":
            return self.model.predict_proba(X)[:, 1]
        classes = list(self.model.classes_)
        proba = self.model.predict_proba(self._scale(X))
        return proba[:, classes.index(IntentClass.intentional.value)]

    def predict_one(self, features: ArrayLike) -> IntentPrediction:
        if self.model is None:
            raise RuntimeError("IntentClassifier is not fitted")
        x = np.asarray(features, dtype=np.float64).reshape(1, -1)
        p_int = float(self._proba_intentional(x)[0])
        return self._gate(x[0], p_int)

    def _gate(self, x: FloatArray, p_int: float) -> IntentPrediction:
        assert self.centroid is not None
        z = self._scale(x.reshape(1, -1))[0]
        distance = float(np.linalg.norm(z - self.centroid))
        ratio = distance / self.ood_threshold if self.ood_threshold > 0 else 0.0
        in_distribution = ratio <= 1.0
        margin = abs(2.0 * p_int - 1.0)
        if not in_distribution or margin < self.min_margin:
            label = IntentClass.unknown.value
        elif p_int >= 0.5:
            label = IntentClass.intentional.value
        else:
            label = IntentClass.accidental.value
        return IntentPrediction(label, p_int, 1.0 - p_int, margin, in_distribution, ratio)

    def predict(self, X: ArrayLike) -> list[str]:
        X = np.asarray(X, dtype=np.float64)
        probabilities = self._proba_intentional(X)
        return [self._gate(x, float(p)).label for x, p in zip(X, probabilities, strict=False)]

    def accuracy(self, X: ArrayLike, y: ArrayLike) -> float:
        X = np.asarray(X, dtype=np.float64)
        y = np.asarray(y).astype(bool)
        p = self._proba_intentional(X) >= 0.5
        return float(np.mean(p == y))

    # -- export ----------------------------------------------------------------------

    def export_json(self) -> dict[str, Any]:
        """Portable spec: forest trees (or calibrated fallback) plus the OOD gate."""

        if (
            self.model is None
            or self.scaler_mean is None
            or self.scaler_std is None
            or self.centroid is None
        ):
            raise RuntimeError("IntentClassifier is not fitted")
        spec: dict[str, Any] = {
            "algorithm": self.algorithm,
            "classes": list(INTENT_CLASSES),
            "feature_names": list(WINDOW_FEATURES),
            "min_margin": self.min_margin,
            "ood": {
                "mean": self.scaler_mean.tolist(),
                "std": self.scaler_std.tolist(),
                "centroid": self.centroid.tolist(),
                "threshold": self.ood_threshold,
            },
        }
        if self.algorithm == "random_forest":
            spec["forest"] = export_forest(
                self.model, classes=list(self.model.classes_), feature_names=list(WINDOW_FEATURES)
            )
        else:
            spec["forest"] = None
            spec["note"] = "non-forest algorithms are exported to ONNX only"
        return spec

    def export_onnx(self, path: str) -> str:
        """Export via skl2onnx (RF/SVM) or xgboost's ONNX converter when installed."""

        if self.model is None:
            raise RuntimeError("IntentClassifier is not fitted")
        try:
            from skl2onnx import convert_sklearn
            from skl2onnx.common.data_types import FloatTensorType
        except ModuleNotFoundError as exc:  # pragma: no cover - optional
            raise RuntimeError("install the 'onnx' extra to export ONNX") from exc
        if self.algorithm == "xgboost":
            from onnxmltools import convert_xgboost  # type: ignore[import-not-found]

            onx = convert_xgboost(
                self.model, initial_types=[("input", FloatTensorType([None, WINDOW_FEATURE_COUNT]))]
            )
        else:
            onx = convert_sklearn(
                self.model,
                initial_types=[("input", FloatTensorType([None, WINDOW_FEATURE_COUNT]))],
                options={id(self.model): {"zipmap": False}} if self.algorithm != "svm" else None,
            )
        with open(path, "wb") as handle:
            handle.write(onx.SerializeToString())
        return path


class IntentRuntime:
    """Pure-NumPy inference from ``IntentClassifier.export_json`` (Dart reference)."""

    def __init__(self, spec: dict[str, Any]) -> None:
        if spec.get("forest") is None:
            raise ValueError("JSON runtime needs a forest export")
        self.forest = TreeEnsembleRuntime(spec["forest"])
        self.min_margin = float(spec["min_margin"])
        ood = spec["ood"]
        self.mean = np.asarray(ood["mean"])
        self.std = np.asarray(ood["std"])
        self.centroid = np.asarray(ood["centroid"])
        self.threshold = float(ood["threshold"])

    def predict(self, features: ArrayLike) -> IntentPrediction:
        x = np.asarray(features, dtype=np.float64)
        proba = self.forest.predict_proba(x)
        p_int = float(proba[self.forest.classes.index(IntentClass.intentional.value)])
        z = (x - self.mean) / self.std
        distance = float(np.linalg.norm(z - self.centroid))
        ratio = distance / self.threshold if self.threshold > 0 else 0.0
        margin = abs(2.0 * p_int - 1.0)
        if ratio > 1.0 or margin < self.min_margin:
            label = IntentClass.unknown.value
        else:
            label = IntentClass.intentional.value if p_int >= 0.5 else IntentClass.accidental.value
        return IntentPrediction(label, p_int, 1.0 - p_int, margin, ratio <= 1.0, ratio)
