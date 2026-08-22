"""Small-data baseline classifiers and out-of-distribution rejection."""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Protocol

import numpy as np
from numpy.typing import ArrayLike, NDArray

FloatArray = NDArray[np.float64]

DEFAULT_DTW_K = 3
DEFAULT_MIN_SPREAD = 0.05
DEFAULT_OOD_MULTIPLIER = 2.2
DEFAULT_CONFIDENCE_THRESHOLD = 0.72


def _sequence(value: ArrayLike, *, name: str = "sequence") -> FloatArray:
    array = np.asarray(value, dtype=np.float64)
    if array.ndim != 2 or array.shape[0] == 0 or array.shape[1] == 0:
        raise ValueError(f"{name} must be a non-empty two-dimensional array")
    if not np.all(np.isfinite(array)):
        raise ValueError(f"{name} must contain only finite values")
    return array


def euclidean_distance(left: ArrayLike, right: ArrayLike) -> float:
    left_array = np.asarray(left, dtype=np.float64)
    right_array = np.asarray(right, dtype=np.float64)
    if left_array.shape != right_array.shape:
        raise ValueError(
            f"vectors must have identical shapes, got {left_array.shape} and {right_array.shape}"
        )
    if not np.all(np.isfinite(left_array)) or not np.all(np.isfinite(right_array)):
        raise ValueError("vectors must contain only finite values")
    return float(np.linalg.norm(left_array - right_array))


def dtw_distance(sequence_a: ArrayLike, sequence_b: ArrayLike) -> float:
    """Dynamic-time-warping distance using the legacy Euclidean frame cost."""

    left = _sequence(sequence_a, name="sequence_a")
    right = _sequence(sequence_b, name="sequence_b")
    if left.shape[1] != right.shape[1]:
        raise ValueError("sequences must have the same feature width")
    previous = np.full(right.shape[0] + 1, np.inf, dtype=np.float64)
    current = np.full(right.shape[0] + 1, np.inf, dtype=np.float64)
    previous[0] = 0.0
    for left_frame in left:
        current.fill(np.inf)
        for right_index, right_frame in enumerate(right, start=1):
            cost = float(np.linalg.norm(left_frame - right_frame))
            current[right_index] = cost + min(
                previous[right_index],
                current[right_index - 1],
                previous[right_index - 1],
            )
        previous, current = current, previous
    return float(previous[-1])


def summary_vector(sequence: ArrayLike) -> FloatArray:
    """Concatenate per-feature mean and population standard deviation."""

    array = _sequence(sequence)
    return np.concatenate((array.mean(axis=0), array.std(axis=0, ddof=0)))


def _fit_centroids(
    sequences_by_class: tuple[tuple[ArrayLike, ...], ...] | list[list[ArrayLike]],
    *,
    min_spread: float,
) -> tuple[FloatArray, FloatArray]:
    if min_spread <= 0 or not math.isfinite(min_spread):
        raise ValueError("min_spread must be a positive finite number")
    if not sequences_by_class:
        raise ValueError("at least one class is required")
    centroids: list[FloatArray] = []
    spreads: list[float] = []
    expected_width: int | None = None
    for class_index, sequences in enumerate(sequences_by_class):
        if not sequences:
            raise ValueError(f"class {class_index} has no training sequences")
        summaries = np.stack(
            [summary_vector(sequence) for sequence in sequences]
        )
        if expected_width is None:
            expected_width = summaries.shape[1]
        elif summaries.shape[1] != expected_width:
            raise ValueError("all classes must use the same feature width")
        centroid = summaries.mean(axis=0)
        spread = float(np.linalg.norm(summaries - centroid, axis=1).mean())
        centroids.append(centroid)
        # The edge client floors every class spread, not only exact-zero
        # spreads. This prevents tiny calibration variance from making the OOD
        # acceptance region unusably narrow.
        spreads.append(max(spread, min_spread))
    return np.stack(centroids), np.asarray(spreads, dtype=np.float64)


class ProbabilityClassifier(Protocol):
    def predict_proba(self, sequence: ArrayLike) -> FloatArray: ...


class DTWKNNClassifier:
    """Inverse-distance weighted DTW k-nearest-neighbour classifier."""

    def __init__(self, k: int = DEFAULT_DTW_K) -> None:
        if isinstance(k, bool) or not isinstance(k, int) or k <= 0:
            raise ValueError("k must be a positive integer")
        self.k = k
        self.sequences: tuple[FloatArray, ...] = ()
        self.labels = np.empty(0, dtype=np.int64)
        self.n_classes = 0
        self.feature_width: int | None = None

    def fit(
        self,
        sequences_by_class: tuple[tuple[ArrayLike, ...], ...] | list[list[ArrayLike]],
    ) -> DTWKNNClassifier:
        if not sequences_by_class:
            raise ValueError("at least one class is required")
        sequences: list[FloatArray] = []
        labels: list[int] = []
        feature_width: int | None = None
        for class_index, class_sequences in enumerate(sequences_by_class):
            if not class_sequences:
                raise ValueError(f"class {class_index} has no training sequences")
            for sequence in class_sequences:
                array = _sequence(sequence)
                if feature_width is None:
                    feature_width = array.shape[1]
                elif array.shape[1] != feature_width:
                    raise ValueError("all sequences must use the same feature width")
                sequences.append(array.copy())
                labels.append(class_index)
        self.sequences = tuple(sequences)
        self.labels = np.asarray(labels, dtype=np.int64)
        self.n_classes = len(sequences_by_class)
        self.feature_width = feature_width
        return self

    def _check_fitted(self) -> None:
        if not self.sequences:
            raise RuntimeError("DTWKNNClassifier has not been fitted")

    def predict_proba(self, sequence: ArrayLike) -> FloatArray:
        self._check_fitted()
        query = _sequence(sequence)
        if query.shape[1] != self.feature_width:
            raise ValueError("query feature width does not match training data")
        distances = [dtw_distance(query, candidate) for candidate in self.sequences]
        # Python's sort is stable, preserving training order for equal distances.
        nearest = sorted(enumerate(distances), key=lambda pair: pair[1])[: self.k]
        votes = np.zeros(self.n_classes, dtype=np.float64)
        for index, distance in nearest:
            votes[self.labels[index]] += 1.0 / (1.0 + distance)
        total = float(votes.sum())
        return votes / (total if total != 0.0 else 1.0)

    def predict(self, sequence: ArrayLike) -> int:
        return int(np.argmax(self.predict_proba(sequence)))


class PrototypeClassifier:
    """Nearest summary-vector centroid with normalized inverse-distance scores."""

    def __init__(self, *, min_spread: float = DEFAULT_MIN_SPREAD) -> None:
        self.min_spread = min_spread
        self.centroids = np.empty((0, 0), dtype=np.float64)
        self.spreads = np.empty(0, dtype=np.float64)

    def fit(
        self,
        sequences_by_class: tuple[tuple[ArrayLike, ...], ...] | list[list[ArrayLike]],
    ) -> PrototypeClassifier:
        self.centroids, self.spreads = _fit_centroids(
            sequences_by_class, min_spread=self.min_spread
        )
        return self

    def _check_fitted(self) -> None:
        if self.centroids.size == 0:
            raise RuntimeError("PrototypeClassifier has not been fitted")

    def predict_proba(self, sequence: ArrayLike) -> FloatArray:
        """Return the web activation confidence at the selected class index.

        FingerSpeak confidence is not a calibrated class-probability
        distribution. The absolute-nearest prototype is selected first, then
        its distance is normalized by that class's spread. Other entries are
        zero so ``argmax`` preserves the exact edge selection contract.
        """

        prediction = self.score(sequence)
        scores = np.zeros(self.centroids.shape[0], dtype=np.float64)
        scores[prediction.nearest_class] = prediction.confidence
        return scores

    def score(
        self,
        sequence: ArrayLike,
        *,
        ood_multiplier: float = DEFAULT_OOD_MULTIPLIER,
    ) -> PrototypePrediction:
        self._check_fitted()
        if ood_multiplier <= 0 or not math.isfinite(ood_multiplier):
            raise ValueError("ood_multiplier must be a positive finite number")
        query = summary_vector(sequence)
        if query.shape[0] != self.centroids.shape[1]:
            raise ValueError("query feature width does not match training data")
        distances = np.linalg.norm(self.centroids - query, axis=1)
        nearest_class = int(np.argmin(distances))
        distance = float(distances[nearest_class])
        spread = float(max(self.spreads[nearest_class], self.min_spread))
        normalized_distance = distance / spread
        return PrototypePrediction(
            nearest_class=nearest_class,
            confidence=1.0 / (1.0 + normalized_distance),
            in_distribution=distance <= spread * ood_multiplier,
            distance=distance,
            spread=spread,
            normalized_distance=normalized_distance,
        )

    def predict(self, sequence: ArrayLike) -> int:
        return self.score(sequence).nearest_class


@dataclass(frozen=True, slots=True)
class PrototypePrediction:
    """The single edge prediction contract shared with the web client."""

    nearest_class: int
    confidence: float
    in_distribution: bool
    distance: float
    spread: float
    normalized_distance: float

    def to_dict(self) -> dict[str, float | int | bool]:
        return {
            "nearest_class": self.nearest_class,
            "confidence": self.confidence,
            "in_distribution": self.in_distribution,
            "distance": self.distance,
            "spread": self.spread,
            "normalized_distance": self.normalized_distance,
        }


@dataclass(frozen=True, slots=True)
class OODScore:
    """Normalized distance of a query to its closest accepted class region."""

    in_distribution: bool
    nearest_class: int
    distance: float
    threshold: float
    ratio: float

    def to_dict(self) -> dict[str, float | int | bool]:
        return {
            "in_distribution": self.in_distribution,
            "nearest_class": self.nearest_class,
            "distance": self.distance,
            "threshold": self.threshold,
            "ratio": self.ratio,
        }


class OODDetector:
    """Class-centroid rejection gate used independently of classifier confidence."""

    def __init__(
        self,
        *,
        multiplier: float = DEFAULT_OOD_MULTIPLIER,
        min_spread: float = DEFAULT_MIN_SPREAD,
    ) -> None:
        if multiplier <= 0 or not math.isfinite(multiplier):
            raise ValueError("multiplier must be a positive finite number")
        self.multiplier = multiplier
        self.min_spread = min_spread
        self.centroids = np.empty((0, 0), dtype=np.float64)
        self.spreads = np.empty(0, dtype=np.float64)

    def fit(
        self,
        sequences_by_class: tuple[tuple[ArrayLike, ...], ...] | list[list[ArrayLike]],
    ) -> OODDetector:
        self.centroids, self.spreads = _fit_centroids(
            sequences_by_class, min_spread=self.min_spread
        )
        return self

    def score(self, sequence: ArrayLike) -> OODScore:
        if self.centroids.size == 0:
            raise RuntimeError("OODDetector has not been fitted")
        query = summary_vector(sequence)
        if query.shape[0] != self.centroids.shape[1]:
            raise ValueError("query feature width does not match training data")
        distances = np.linalg.norm(self.centroids - query, axis=1)
        # Select by absolute distance first, exactly as the web edge predictor
        # does, then apply that class's normalized OOD threshold.
        nearest_class = int(np.argmin(distances))
        threshold = float(max(self.spreads[nearest_class], self.min_spread) * self.multiplier)
        ratio = float(distances[nearest_class] / threshold)
        return OODScore(
            in_distribution=ratio <= 1.0,
            nearest_class=nearest_class,
            distance=float(distances[nearest_class]),
            threshold=threshold,
            ratio=ratio,
        )

    def is_in_distribution(self, sequence: ArrayLike) -> bool:
        return self.score(sequence).in_distribution
