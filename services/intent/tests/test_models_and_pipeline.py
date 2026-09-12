from __future__ import annotations

import json

import numpy as np
import pytest

from neurobridge_intent.bundle import train_and_export, verify_bundle
from neurobridge_intent.calibration import CalibrationError, CalibrationSession, PatientProfile
from neurobridge_intent.features.window import FrameFeatures
from neurobridge_intent.models.abnormal import AbnormalMovementDetector, AbnormalRuntime, rule_floor
from neurobridge_intent.models.intent_classifier import IntentClassifier, IntentRuntime
from neurobridge_intent.models.temporal import TemporalRuntime, random_runtime
from neurobridge_intent.models.tree_export import TreeEnsembleRuntime, export_forest
from neurobridge_intent.pipeline import IntentPipeline, ModelBundle, run_clip
from neurobridge_intent.schema import (
    FRAME_FEATURE_COUNT,
    SEQUENCE_FRAMES,
    WINDOW_FEATURES,
    AbnormalClass,
    CalibrationPhase,
    CommandClass,
    IntentClass,
)
from neurobridge_intent.synthetic import (
    generate_abnormal,
    generate_command,
    generate_random_movement,
)
from neurobridge_intent.verification import Decision


def test_intent_classifier_learns_and_json_runtime_matches(training_data):
    X, y = training_data.window_X, training_data.intentional
    clf = IntentClassifier(n_estimators=40).fit(X, y)
    assert clf.accuracy(X, y) > 0.9
    runtime = IntentRuntime(clf.export_json())
    for row in X[:25]:
        expected = clf.predict_one(row)
        actual = runtime.predict(row)
        assert actual.label == expected.label
        assert actual.p_intentional == pytest.approx(expected.p_intentional, abs=1e-9)
    # Far out-of-distribution windows are reported as unknown, never intentional.
    outlier = X[0] + 1e4
    assert runtime.predict(outlier).label == IntentClass.unknown.value


def test_tree_export_probabilities_match_sklearn(training_data):
    from sklearn.ensemble import RandomForestClassifier

    X, y = training_data.window_X, training_data.abnormal
    forest = RandomForestClassifier(n_estimators=15, max_depth=6, random_state=0).fit(X, y)
    runtime = TreeEnsembleRuntime(
        export_forest(forest, classes=list(forest.classes_), feature_names=list(WINDOW_FEATURES))
    )
    np.testing.assert_allclose(
        runtime.predict_proba(X[3]), forest.predict_proba(X[3:4])[0], atol=1e-9
    )
    assert runtime.predict(X[3]) == forest.predict(X[3:4])[0]


def test_abnormal_detector_rule_floor_and_runtime(training_data):
    X, labels = training_data.window_X, training_data.abnormal
    detector = AbnormalMovementDetector(n_estimators=40).fit(X, labels)
    assert detector.accuracy(X, labels) > 0.9
    runtime = AbnormalRuntime(detector.export_json())
    seizure_rows = X[labels == AbnormalClass.possible_seizure_like.value]
    hits = sum(
        runtime.predict(row).label == AbnormalClass.possible_seizure_like.value
        for row in seizure_rows
    )
    assert hits >= 0.8 * len(seizure_rows)
    # The floor only ever raises abnormal probabilities.
    rule, floors = rule_floor(np.zeros(len(WINDOW_FEATURES)))
    assert rule is None and all(v == 0.0 for v in floors.values())


def test_temporal_runtime_shapes_and_softmax():
    runtime = random_runtime(seed=1)
    proba = runtime.predict_proba(np.zeros((SEQUENCE_FRAMES, FRAME_FEATURE_COUNT)))
    assert proba.shape == (len(CommandClass),)
    assert proba.sum() == pytest.approx(1.0)
    with pytest.raises(ValueError):
        runtime.predict_proba(np.zeros((3, FRAME_FEATURE_COUNT)))


def test_calibration_requires_all_phases_and_serialises(profile, tmp_path):
    assert profile.blink["rate_per_min"] > 5
    assert set(profile.prototypes) == {p.value for p in CalibrationPhase}
    path = profile.save(tmp_path / "patient_profile.json")
    loaded = PatientProfile.load(path)
    assert loaded.patient_id == profile.patient_id
    assert loaded.normalizer["mean"] == profile.normalizer["mean"]
    session = CalibrationSession(patient_id="short")
    session.add_frame(
        CalibrationPhase.rest_state, FrameFeatures(0.0, np.zeros(FRAME_FEATURE_COUNT))
    )
    with pytest.raises(CalibrationError):
        session.build_profile()
    bad = profile.to_dict()
    bad["schema_version"] = "other"
    with pytest.raises(CalibrationError):
        PatientProfile.from_dict(bad)


def test_bundle_round_trip_without_tensorflow(tmp_path, dataset):
    manifest = train_and_export(
        tmp_path / "bundle", clips=dataset, with_temporal=False, with_onnx=False, seed=1
    )
    assert manifest["metrics"]["intent_accuracy"] > 0.8
    assert verify_bundle(tmp_path / "bundle") == []
    bundle = ModelBundle.load(tmp_path / "bundle")
    assert isinstance(bundle.temporal, TemporalRuntime)
    (tmp_path / "bundle" / "abnormal_rf.json").write_text("{}", encoding="utf-8")
    assert "abnormal_rf.json checksum mismatch" in verify_bundle(tmp_path / "bundle")


@pytest.fixture(scope="module")
def pipeline_bundle(tmp_path_factory, dataset):
    directory = tmp_path_factory.mktemp("bundle")
    train_and_export(directory, clips=dataset, with_temporal=False, with_onnx=False, seed=1)
    return ModelBundle.load(directory)


def test_pipeline_never_executes_on_abnormal_movement(pipeline_bundle, profile, rng):
    pipeline = IntentPipeline(pipeline_bundle, profile)
    for kind in (
        AbnormalClass.possible_seizure_like,
        AbnormalClass.possible_spasm,
        AbnormalClass.involuntary,
    ):
        pipeline.reset()
        verdicts = run_clip(pipeline, generate_abnormal(rng, kind, seconds=5.0).values)
        assert all(v.decision != Decision.execute for v in verdicts), kind
    pipeline.reset()
    verdicts = run_clip(
        pipeline, generate_abnormal(rng, AbnormalClass.possible_seizure_like, seconds=5.0).values
    )
    assert any(v.decision == Decision.alert for v in verdicts)


def test_pipeline_ignores_rest_and_random_movement(pipeline_bundle, profile, rng):
    pipeline = IntentPipeline(pipeline_bundle, profile)
    for _ in range(3):
        pipeline.reset()
        verdicts = run_clip(pipeline, generate_random_movement(rng, seconds=5.0).values)
        assert all(v.decision != Decision.execute for v in verdicts)
        pipeline.reset()
        verdicts = run_clip(
            pipeline, generate_command(rng, CommandClass.non_command, seconds=5.0).values
        )
        assert all(v.decision != Decision.execute for v in verdicts)


def test_pipeline_event_payload_is_camera_free(pipeline_bundle, profile, rng):
    pipeline = IntentPipeline(pipeline_bundle, profile)
    run_clip(pipeline, generate_command(rng, CommandClass.triple_blink, seconds=4.0).values)
    payload = pipeline.event_payload(patient_history="usually uses triple blink for assistance")
    text = json.dumps(payload).lower()
    for forbidden in ("landmark", "frame", "image", "pixel"):
        assert forbidden not in text
    assert payload["profile"]["patient_id"] == profile.patient_id
    assert pipeline.signal_for(CommandClass.triple_blink) == "rapidBlink"
    assert pipeline.signal_for(CommandClass.non_command) is None
