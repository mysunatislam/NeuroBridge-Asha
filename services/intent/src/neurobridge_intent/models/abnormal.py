"""Phase 3: abnormal movement detection.

Input: optical-flow channels + landmark channels + temporal window features.
Output: normal_voluntary / involuntary / possible_spasm / possible_seizure_like.

A Random Forest learns the fine distinctions; ``rule_floor`` is a transparent
safety net that can only *raise* the seizure-like and spasm probabilities when the
physics is unambiguous (sustained rhythmic 2.5-6 Hz high-amplitude motion, or a
very high jerk transient with no hold phase). Neither path diagnoses a condition;
they gate commands and raise a caregiver alert for review.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import numpy as np
from numpy.typing import ArrayLike, NDArray

from ..schema import ABNORMAL_CLASSES, WINDOW_FEATURE_COUNT, WINDOW_FEATURES, AbnormalClass
from .tree_export import TreeEnsembleRuntime, export_forest

FloatArray = NDArray[np.float64]

_W = {name: index for index, name in enumerate(WINDOW_FEATURES)}


@dataclass(frozen=True, slots=True)
class AbnormalPrediction:
    label: str
    probabilities: dict[str, float]
    rule_triggered: str | None

    @property
    def p_abnormal(self) -> float:
        return 1.0 - self.probabilities.get(AbnormalClass.normal_voluntary.value, 0.0)

    def to_dict(self) -> dict[str, Any]:
        return {
            "label": self.label,
            "probabilities": self.probabilities,
            "rule_triggered": self.rule_triggered,
        }


def rule_floor(
    features: ArrayLike, *, rest_hf_ratio: float = 0.2, rest_rhythmicity: float = 0.2
) -> tuple[str | None, dict[str, float]]:
    """Physics-based minimum probabilities. Returns (rule name, floor probabilities)."""

    x = np.asarray(features, dtype=np.float64)
    head_hz = x[_W["head_dominant_hz"]]
    rhythm = x[_W["head_rhythmicity"]]
    sustained = x[_W["sustained_seconds"]]
    yaw_range = x[_W["head_yaw_range"]]
    flow_hf = x[_W["flow_hf_ratio_mean"]]
    flow_mean = x[_W["flow_mag_mean_mean"]]
    jerk = x[_W["face_jerk_rms"]]
    hold = x[_W["hold_fraction"]]
    peak = x[_W["peak_amplitude"]]
    floors = {name: 0.0 for name in ABNORMAL_CLASSES}
    rule = None
    if (
        2.5 <= head_hz <= 6.5
        and rhythm > max(0.45, rest_rhythmicity + 0.25)
        and sustained >= 1.5
        and yaw_range >= 8.0
    ):
        floors[AbnormalClass.possible_seizure_like.value] = 0.85
        rule = "sustained_rhythmic_high_amplitude"
    elif flow_hf > max(0.55, rest_hf_ratio + 0.3) and yaw_range < 6.0 and flow_mean > 0.03:
        floors[AbnormalClass.involuntary.value] = 0.6
        rule = "high_frequency_low_amplitude"
    elif (
        jerk > 0.0
        and peak > 0.0
        and hold < 0.15
        and x[_W["onset_count"]] <= 2
        and yaw_range >= 12.0
        and x[_W["head_angular_speed_max"]] >= 120.0
    ):
        floors[AbnormalClass.possible_spasm.value] = 0.6
        rule = "high_jerk_no_hold"
    return rule, floors


class AbnormalMovementDetector:
    def __init__(
        self, *, n_estimators: int = 120, max_depth: int | None = 12, random_state: int = 11
    ) -> None:
        self.n_estimators = n_estimators
        self.max_depth = max_depth
        self.random_state = random_state
        self.model: Any | None = None
        self.rest_hf_ratio = 0.2
        self.rest_rhythmicity = 0.2

    def fit(self, X: ArrayLike, labels: ArrayLike) -> AbnormalMovementDetector:
        from sklearn.ensemble import RandomForestClassifier

        X = np.asarray(X, dtype=np.float64)
        if X.ndim != 2 or X.shape[1] != WINDOW_FEATURE_COUNT:
            raise ValueError(f"X must be (n, {WINDOW_FEATURE_COUNT})")
        y = np.asarray([str(label) for label in labels])
        unknown = set(y) - set(ABNORMAL_CLASSES)
        if unknown:
            raise ValueError(f"unknown abnormal labels: {sorted(unknown)}")
        model = RandomForestClassifier(
            n_estimators=self.n_estimators,
            max_depth=self.max_depth,
            min_samples_leaf=2,
            class_weight="balanced",
            random_state=self.random_state,
            n_jobs=1,
        )
        model.fit(X, y)
        self.model = model
        return self

    def set_patient_baseline(self, *, rest_hf_ratio: float, rest_rhythmicity: float) -> None:
        self.rest_hf_ratio = rest_hf_ratio
        self.rest_rhythmicity = rest_rhythmicity

    def predict_one(self, features: ArrayLike) -> AbnormalPrediction:
        if self.model is None:
            raise RuntimeError("AbnormalMovementDetector is not fitted")
        x = np.asarray(features, dtype=np.float64)
        proba = self.model.predict_proba(x.reshape(1, -1))[0]
        probabilities = {
            str(cls): float(p) for cls, p in zip(self.model.classes_, proba, strict=False)
        }
        return combine_with_floor(
            probabilities,
            x,
            rest_hf_ratio=self.rest_hf_ratio,
            rest_rhythmicity=self.rest_rhythmicity,
        )

    def accuracy(self, X: ArrayLike, labels: ArrayLike) -> float:
        X = np.asarray(X, dtype=np.float64)
        predicted = [self.predict_one(x).label for x in X]
        return float(np.mean(np.asarray(predicted) == np.asarray([str(v) for v in labels])))

    def export_json(self) -> dict[str, Any]:
        if self.model is None:
            raise RuntimeError("AbnormalMovementDetector is not fitted")
        return {
            "classes": list(ABNORMAL_CLASSES),
            "feature_names": list(WINDOW_FEATURES),
            "forest": export_forest(
                self.model,
                classes=[str(c) for c in self.model.classes_],
                feature_names=list(WINDOW_FEATURES),
            ),
            "rule_floor": {
                "rest_hf_ratio": self.rest_hf_ratio,
                "rest_rhythmicity": self.rest_rhythmicity,
            },
        }


def combine_with_floor(
    probabilities: dict[str, float],
    features: FloatArray,
    *,
    rest_hf_ratio: float,
    rest_rhythmicity: float,
) -> AbnormalPrediction:
    rule, floors = rule_floor(
        features, rest_hf_ratio=rest_hf_ratio, rest_rhythmicity=rest_rhythmicity
    )
    merged = {name: max(probabilities.get(name, 0.0), floors[name]) for name in ABNORMAL_CLASSES}
    total = sum(merged.values()) or 1.0
    merged = {name: value / total for name, value in merged.items()}
    label = max(merged, key=merged.__getitem__)
    return AbnormalPrediction(label, merged, rule)


class AbnormalRuntime:
    """NumPy inference from ``AbnormalMovementDetector.export_json`` (Dart reference)."""

    def __init__(self, spec: dict[str, Any]) -> None:
        self.forest = TreeEnsembleRuntime(spec["forest"])
        floor = spec.get("rule_floor", {})
        self.rest_hf_ratio = float(floor.get("rest_hf_ratio", 0.2))
        self.rest_rhythmicity = float(floor.get("rest_rhythmicity", 0.2))

    def predict(self, features: ArrayLike) -> AbnormalPrediction:
        x = np.asarray(features, dtype=np.float64)
        proba = self.forest.predict_proba(x)
        probabilities = {cls: float(p) for cls, p in zip(self.forest.classes, proba, strict=False)}
        return combine_with_floor(
            probabilities,
            x,
            rest_hf_ratio=self.rest_hf_ratio,
            rest_rhythmicity=self.rest_rhythmicity,
        )
