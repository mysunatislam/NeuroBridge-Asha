"""Portable JSON representation of scikit-learn tree ensembles.

The Dart runtime (``apps/mobile/lib/intent/tree_ensemble.dart``) walks the same
arrays, so a Random Forest trained here runs offline on Android, iOS and web with
bit-identical decisions (comparisons are ``value <= threshold`` on float64).
"""

from __future__ import annotations

from typing import Any

import numpy as np
from numpy.typing import ArrayLike, NDArray

FloatArray = NDArray[np.float64]


def export_forest(model: Any, *, classes: list[str], feature_names: list[str]) -> dict[str, Any]:
    """Serialise a fitted ``RandomForestClassifier`` / ``ExtraTreesClassifier``."""

    estimators = getattr(model, "estimators_", None)
    if estimators is None:
        raise ValueError("model must be a fitted scikit-learn forest")
    trees = []
    for estimator in estimators:
        tree = estimator.tree_
        values = tree.value[:, 0, :]
        # Leaf class distributions are normalised so every tree votes with probabilities.
        totals = values.sum(axis=1, keepdims=True)
        probabilities = np.divide(values, totals, out=np.zeros_like(values), where=totals > 0)
        trees.append(
            {
                "left": tree.children_left.astype(int).tolist(),
                "right": tree.children_right.astype(int).tolist(),
                "feature": tree.feature.astype(int).tolist(),
                "threshold": tree.threshold.astype(float).tolist(),
                "value": probabilities.astype(float).tolist(),
            }
        )
    return {
        "type": "forest",
        "classes": list(classes),
        "feature_names": list(feature_names),
        "n_features": len(feature_names),
        "trees": trees,
    }


class TreeEnsembleRuntime:
    """NumPy evaluator for :func:`export_forest` output (reference for the Dart port)."""

    def __init__(self, spec: dict[str, Any]) -> None:
        if spec.get("type") != "forest":
            raise ValueError("spec is not a forest")
        self.classes: list[str] = list(spec["classes"])
        self.n_features = int(spec["n_features"])
        self.trees = [
            (
                np.asarray(t["left"], dtype=np.int64),
                np.asarray(t["right"], dtype=np.int64),
                np.asarray(t["feature"], dtype=np.int64),
                np.asarray(t["threshold"], dtype=np.float64),
                np.asarray(t["value"], dtype=np.float64),
            )
            for t in spec["trees"]
        ]

    def predict_proba(self, features: ArrayLike) -> FloatArray:
        x = np.asarray(features, dtype=np.float64)
        if x.shape != (self.n_features,):
            raise ValueError(f"expected {self.n_features} features, got {x.shape}")
        total = np.zeros(len(self.classes), dtype=np.float64)
        for left, right, feature, threshold, value in self.trees:
            node = 0
            while left[node] != -1:
                node = left[node] if x[feature[node]] <= threshold[node] else right[node]
            total += value[node]
        return total / len(self.trees) if self.trees else total

    def predict(self, features: ArrayLike) -> str:
        return self.classes[int(np.argmax(self.predict_proba(features)))]
