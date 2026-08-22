"""Dependency-light classification metrics used by browser and Python models."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import numpy as np
from numpy.typing import ArrayLike, NDArray

from .classifiers import ProbabilityClassifier

IntArray = NDArray[np.int64]


@dataclass(frozen=True, slots=True)
class ClassMetrics:
    precision: float
    recall: float
    f1: float
    support: int

    def to_dict(self) -> dict[str, float | int]:
        return {
            "precision": self.precision,
            "recall": self.recall,
            "f1": self.f1,
            "support": self.support,
        }


@dataclass(frozen=True, slots=True)
class EvaluationResult:
    accuracy: float
    confusion_matrix: IntArray
    per_class: tuple[ClassMetrics, ...]
    total: int

    def to_dict(self, class_names: tuple[str, ...] | None = None) -> dict[str, Any]:
        if class_names is not None and len(class_names) != len(self.per_class):
            raise ValueError("class_names length does not match evaluation classes")
        labels = class_names or tuple(str(index) for index in range(len(self.per_class)))
        return {
            "accuracy": self.accuracy,
            "total": self.total,
            "confusion_matrix": self.confusion_matrix.tolist(),
            "per_class": {
                label: metrics.to_dict()
                for label, metrics in zip(labels, self.per_class, strict=True)
            },
        }


def confusion_matrix(y_true: ArrayLike, y_predicted: ArrayLike, n_classes: int) -> IntArray:
    if isinstance(n_classes, bool) or not isinstance(n_classes, int) or n_classes <= 0:
        raise ValueError("n_classes must be a positive integer")
    true = np.asarray(y_true)
    predicted = np.asarray(y_predicted)
    if true.ndim != 1 or predicted.ndim != 1 or true.shape != predicted.shape:
        raise ValueError("labels must be one-dimensional arrays with identical shapes")
    if not np.issubdtype(true.dtype, np.integer) or not np.issubdtype(predicted.dtype, np.integer):
        raise ValueError("labels must be integers")
    true = true.astype(np.int64, copy=False)
    predicted = predicted.astype(np.int64, copy=False)
    if true.size and (
        true.min() < 0
        or predicted.min() < 0
        or true.max() >= n_classes
        or predicted.max() >= n_classes
    ):
        raise ValueError("label is outside the configured class range")
    matrix = np.zeros((n_classes, n_classes), dtype=np.int64)
    np.add.at(matrix, (true, predicted), 1)
    return matrix


def evaluate_predictions(
    y_true: ArrayLike,
    y_predicted: ArrayLike,
    n_classes: int,
) -> EvaluationResult:
    matrix = confusion_matrix(y_true, y_predicted, n_classes)
    total = int(matrix.sum())
    correct = int(np.trace(matrix))
    row_totals = matrix.sum(axis=1)
    column_totals = matrix.sum(axis=0)
    class_metrics: list[ClassMetrics] = []
    for class_index in range(n_classes):
        true_positive = int(matrix[class_index, class_index])
        precision = (
            true_positive / int(column_totals[class_index])
            if column_totals[class_index]
            else 0.0
        )
        recall = (
            true_positive / int(row_totals[class_index])
            if row_totals[class_index]
            else 0.0
        )
        f1 = 2.0 * precision * recall / (precision + recall) if precision + recall else 0.0
        class_metrics.append(
            ClassMetrics(
                precision=precision,
                recall=recall,
                f1=f1,
                support=int(row_totals[class_index]),
            )
        )
    return EvaluationResult(
        accuracy=correct / total if total else 0.0,
        confusion_matrix=matrix,
        per_class=tuple(class_metrics),
        total=total,
    )


def evaluate_classifier(
    classifier: ProbabilityClassifier,
    sequences_by_class: tuple[tuple[ArrayLike, ...], ...],
) -> EvaluationResult:
    y_true: list[int] = []
    y_predicted: list[int] = []
    for class_index, sequences in enumerate(sequences_by_class):
        for sequence in sequences:
            probabilities = np.asarray(classifier.predict_proba(sequence), dtype=np.float64)
            if probabilities.shape != (len(sequences_by_class),):
                raise ValueError("classifier returned an unexpected probability shape")
            if not np.all(np.isfinite(probabilities)):
                raise ValueError("classifier returned non-finite probabilities")
            y_true.append(class_index)
            y_predicted.append(int(np.argmax(probabilities)))
    return evaluate_predictions(y_true, y_predicted, len(sequences_by_class))
