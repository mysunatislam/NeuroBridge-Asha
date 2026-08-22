from __future__ import annotations

import json

import numpy as np
import pytest

from fingerspeak_ml.bundle import (
    EDGE_PROTOTYPE_FILENAME,
    BundleValidationError,
    canonical_profile_binding_bytes,
    load_model_manifest,
    training_profile_sha256,
    validate_edge_prototype_artifact,
    validate_model_manifest,
    write_model_bundle,
)
from fingerspeak_ml.classifiers import (
    DTWKNNClassifier,
    OODDetector,
    PrototypeClassifier,
)
from fingerspeak_ml.cli import main
from fingerspeak_ml.dataset import all_sequences_by_class
from fingerspeak_ml.schema import CalibrationSample, Gesture, Profile, validate_profile


def _golden_binding_profile(captured_at: str) -> Profile:
    rest_raw = np.zeros((20, 63), dtype=np.float64)
    yes_raw = np.zeros((20, 63), dtype=np.float64)
    yes_raw[0, 0] = 1.5
    yes_raw[19, 62] = -2.25
    return Profile(
        version=3,
        identifier="golden-profile",
        name="Excluded profile name",
        updated_at="2026-08-15T10:00:00Z",
        gestures=(
            Gesture(
                identifier="rest",
                name="Rest",
                phrase="",
                icon="hand",
                protected=True,
                risk="routine",
                dwell_ms=650,
                samples=(
                    CalibrationSample(
                        raw=rest_raw,
                        session="s1",
                        captured_at=captured_at,
                    ),
                ),
            ),
            Gesture(
                identifier="yes.v1",
                name="Yes",
                phrase="Yes.",
                icon="hand",
                risk="clinical",
                dwell_ms=1000,
                samples=(
                    CalibrationSample(
                        raw=yes_raw,
                        session="s2",
                        captured_at=captured_at,
                    ),
                ),
            ),
        ),
    )


def test_training_profile_sha256_matches_cross_runtime_golden_vector() -> None:
    profile = _golden_binding_profile("2026-08-15T10:00:00Z")
    encoded = canonical_profile_binding_bytes(profile)
    assert len(encoded) == 20_291
    assert training_profile_sha256(profile) == (
        "3e4bf74ae01df86b64e4df133b78090e01017f6f3eacc7c1c314dc8690667332"
    )
    changed_timestamp = _golden_binding_profile("2030-01-01T00:00:00Z")
    assert canonical_profile_binding_bytes(changed_timestamp) == encoded


def test_bundle_round_trip_and_checksum(profile_payload: dict, tmp_path) -> None:
    profile_payload["gestures"][1]["id"] = "g.yes-v1"
    profile = validate_profile(profile_payload, require_trainable=True)
    sequences = all_sequences_by_class(profile)
    dtw = DTWKNNClassifier().fit(sequences)
    prototype = PrototypeClassifier().fit(sequences)
    ood = OODDetector().fit(sequences)
    manifest_path = write_model_bundle(
        tmp_path / "bundle",
        profile=profile,
        dtw=dtw,
        prototype=prototype,
        ood=ood,
        metrics={"prototype": {"accuracy": 1.0}},
    )
    manifest = load_model_manifest(manifest_path)
    assert manifest["feature"]["engineered_feature_length"] == 98
    assert manifest["training_profile_sha256"] == training_profile_sha256(profile)
    assert [entry["name"] for entry in manifest["classes"]] == ["Rest", "Yes"]
    assert [entry["gesture_id"] for entry in manifest["classes"]] == [
        "rest",
        "g.yes-v1",
    ]
    assert {entry["confidence_threshold"] for entry in manifest["classes"]} == {0.72}
    assert manifest["classes"][0]["dwell_ms"] == profile.gestures[0].dwell_ms
    assert (manifest_path.parent / "baselines.npz").is_file()
    edge_path = manifest_path.parent / EDGE_PROTOTYPE_FILENAME
    edge = validate_edge_prototype_artifact(json.loads(edge_path.read_text(encoding="utf-8")))
    assert [entry["gesture_id"] for entry in edge["prototypes"]] == [
        "rest",
        "g.yes-v1",
    ]
    assert all(len(entry["centroid"]) == 196 for entry in edge["prototypes"])
    assert all(entry["spread"] >= 0.05 for entry in edge["prototypes"])
    assert any(
        artifact["path"] == EDGE_PROTOTYPE_FILENAME for artifact in manifest["artifacts"]
    )

    invalid_manifest = json.loads(json.dumps(manifest))
    invalid_manifest["classes"][1]["gesture_id"] = ".leading-dot"
    with pytest.raises(BundleValidationError, match="gesture_id"):
        validate_model_manifest(invalid_manifest)

    invalid_manifest = json.loads(json.dumps(manifest))
    invalid_manifest["training_profile_sha256"] = manifest[
        "training_profile_sha256"
    ].upper()
    with pytest.raises(BundleValidationError, match="training_profile_sha256"):
        validate_model_manifest(invalid_manifest)

    invalid_edge = json.loads(json.dumps(edge))
    invalid_edge["prototypes"][1]["gesture_id"] = "-leading-hyphen"
    with pytest.raises(BundleValidationError, match="gesture identifiers"):
        validate_edge_prototype_artifact(invalid_edge)

    baseline_path = manifest_path.parent / "baselines.npz"
    baseline_path.write_bytes(baseline_path.read_bytes() + b"tamper")
    with pytest.raises(BundleValidationError, match="size mismatch"):
        load_model_manifest(manifest_path)


def test_manifest_rejects_path_traversal(profile_payload: dict, tmp_path) -> None:
    profile = validate_profile(profile_payload, require_trainable=True)
    sequences = all_sequences_by_class(profile)
    manifest_path = write_model_bundle(
        tmp_path / "bundle",
        profile=profile,
        dtw=DTWKNNClassifier().fit(sequences),
        prototype=PrototypeClassifier().fit(sequences),
        ood=OODDetector().fit(sequences),
    )
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    payload["artifacts"][0]["path"] = "../escape.bin"
    with pytest.raises(BundleValidationError, match="safe relative"):
        validate_model_manifest(payload)


def test_edge_artifact_rejects_contract_drift(profile_payload: dict, tmp_path) -> None:
    profile = validate_profile(profile_payload, require_trainable=True)
    sequences = all_sequences_by_class(profile)
    manifest_path = write_model_bundle(
        tmp_path / "bundle",
        profile=profile,
        dtw=DTWKNNClassifier().fit(sequences),
        prototype=PrototypeClassifier().fit(sequences),
        ood=OODDetector().fit(sequences),
    )
    edge_path = manifest_path.parent / EDGE_PROTOTYPE_FILENAME
    payload = json.loads(edge_path.read_text(encoding="utf-8"))
    payload["confidence_threshold"] = 0.75
    with pytest.raises(BundleValidationError, match="threshold"):
        validate_edge_prototype_artifact(payload)


def test_cli_validate_evaluate_and_baseline_train(profile_payload: dict, tmp_path, capsys) -> None:
    profile_path = tmp_path / "profile.json"
    profile_path.write_text(json.dumps(profile_payload), encoding="utf-8")

    assert main(["validate", str(profile_path), "--trainable"]) == 0
    validation_output = json.loads(capsys.readouterr().out)
    assert validation_output["valid"] is True
    assert validation_output["samples"] == 8

    assert main(["evaluate", str(profile_path), "--model", "both"]) == 0
    evaluation_output = json.loads(capsys.readouterr().out)
    assert evaluation_output["validation_kind"] == "independent-session"
    assert set(evaluation_output) >= {"dtw", "prototype"}

    bundle_path = tmp_path / "trained-bundle"
    assert main(["train", str(profile_path), "--output", str(bundle_path)]) == 0
    training_output = json.loads(capsys.readouterr().out)
    assert training_output["backend"] == "baseline"
    assert (bundle_path / "manifest.json").is_file()


def test_cli_reports_validation_error(tmp_path, capsys) -> None:
    invalid = tmp_path / "invalid.json"
    invalid.write_text('{"version":2,"gestures":[]}', encoding="utf-8")
    assert main(["validate", str(invalid)]) == 2
    assert "must contain at least one gesture" in capsys.readouterr().err
