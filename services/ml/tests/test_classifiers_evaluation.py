from __future__ import annotations

import numpy as np
import pytest

from fingerspeak_ml.classifiers import (
    DEFAULT_MIN_SPREAD,
    DTWKNNClassifier,
    OODDetector,
    PrototypeClassifier,
    dtw_distance,
    summary_vector,
)
from fingerspeak_ml.evaluation import (
    confusion_matrix,
    evaluate_classifier,
    evaluate_predictions,
)


def sequence(values: list[float]) -> np.ndarray:
    values_array = np.asarray(values, dtype=np.float64)
    return np.column_stack((values_array, values_array * 0.5))


def training_sequences():
    return (
        (sequence([0.0, 1.0, 2.0, 3.0]), sequence([0.1, 1.1, 2.1, 3.1])),
        (sequence([8.0, 9.0, 10.0, 11.0]), sequence([8.1, 9.1, 10.1, 11.1])),
    )


def test_dtw_prefers_time_warped_same_motion() -> None:
    original = sequence([0.0, 1.0, 2.0, 3.0])
    warped = sequence([0.0, 0.0, 1.0, 2.0, 3.0, 3.0])
    different = sequence([3.0, 2.0, 1.0, 0.0])
    assert dtw_distance(original, warped) < dtw_distance(original, different)


def test_dtw_knn_predicts_and_normalizes_probabilities() -> None:
    classifier = DTWKNNClassifier(k=3).fit(training_sequences())
    probabilities = classifier.predict_proba(sequence([0.05, 1.0, 2.0, 3.0]))
    assert probabilities.shape == (2,)
    assert probabilities.sum() == pytest.approx(1.0)
    assert classifier.predict(sequence([0.05, 1.0, 2.0, 3.0])) == 0
    assert classifier.predict(sequence([8.0, 9.0, 10.0, 11.0])) == 1


def test_prototype_classifier_and_summary_use_population_std() -> None:
    summary = summary_vector([[0.0], [2.0]])
    np.testing.assert_allclose(summary, [1.0, 1.0])
    classifier = PrototypeClassifier().fit(training_sequences())
    query = sequence([8.0, 9.0, 10.0, 11.0])
    prediction = classifier.score(query)
    scores = classifier.predict_proba(query)
    assert prediction.nearest_class == 1
    assert classifier.predict(query) == 1
    assert scores[1] == pytest.approx(prediction.confidence)
    assert np.count_nonzero(scores) == 1
    assert np.all(classifier.spreads >= DEFAULT_MIN_SPREAD)


def test_prototype_spread_has_a_hard_point_zero_five_floor() -> None:
    classes = (
        (np.asarray([[0.0]]), np.asarray([[0.001]])),
        (np.asarray([[1.0]]), np.asarray([[1.001]])),
    )
    classifier = PrototypeClassifier().fit(classes)
    np.testing.assert_array_equal(
        classifier.spreads, np.asarray([DEFAULT_MIN_SPREAD, DEFAULT_MIN_SPREAD])
    )


def test_prototype_and_ood_select_absolute_nearest_before_normalizing() -> None:
    query = np.asarray([[0.12]])  # summary = [mean 0.12, std 0]
    centroids = np.asarray([[0.0, 0.0], [0.30, 0.0]])
    spreads = np.asarray([0.05, 1.0])

    classifier = PrototypeClassifier()
    classifier.centroids = centroids
    classifier.spreads = spreads
    prediction = classifier.score(query)
    assert prediction.nearest_class == 0
    assert prediction.normalized_distance == pytest.approx(2.4)
    assert prediction.confidence == pytest.approx(1.0 / 3.4)
    assert not prediction.in_distribution

    detector = OODDetector()
    detector.centroids = centroids
    detector.spreads = spreads
    ood = detector.score(query)
    assert ood.nearest_class == 0
    assert not ood.in_distribution


def test_ood_score_accepts_known_and_rejects_far_motion() -> None:
    detector = OODDetector().fit(training_sequences())
    known = detector.score(sequence([0.05, 1.0, 2.0, 3.0]))
    unknown = detector.score(sequence([100.0, 101.0, 102.0, 103.0]))
    assert known.in_distribution
    assert known.ratio <= 1.0
    assert not unknown.in_distribution
    assert unknown.ratio > 1.0
    assert unknown.threshold > 0


def test_classifiers_require_fit() -> None:
    with pytest.raises(RuntimeError, match="not been fitted"):
        DTWKNNClassifier().predict_proba(sequence([0.0, 1.0]))
    with pytest.raises(RuntimeError, match="not been fitted"):
        PrototypeClassifier().predict_proba(sequence([0.0, 1.0]))
    with pytest.raises(RuntimeError, match="not been fitted"):
        OODDetector().score(sequence([0.0, 1.0]))


def test_evaluation_metrics_match_confusion_matrix() -> None:
    matrix = confusion_matrix(
        np.asarray([0, 0, 1, 1]), np.asarray([0, 1, 1, 1]), n_classes=2
    )
    np.testing.assert_array_equal(matrix, [[1, 1], [0, 2]])
    result = evaluate_predictions(
        np.asarray([0, 0, 1, 1]), np.asarray([0, 1, 1, 1]), n_classes=2
    )
    assert result.accuracy == pytest.approx(0.75)
    assert result.per_class[0].precision == pytest.approx(1.0)
    assert result.per_class[0].recall == pytest.approx(0.5)
    assert result.per_class[1].f1 == pytest.approx(0.8)


def test_evaluate_classifier_uses_all_sequences() -> None:
    classes = training_sequences()
    classifier = PrototypeClassifier().fit(classes)
    result = evaluate_classifier(classifier, classes)
    assert result.total == 4
    assert result.accuracy == pytest.approx(1.0)
