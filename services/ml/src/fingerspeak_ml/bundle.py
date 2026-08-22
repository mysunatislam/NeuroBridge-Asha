"""Versioned, checksummed model bundles consumed by the local-first web app."""

from __future__ import annotations

import hashlib
import json
import math
import struct
from collections.abc import Mapping, Sequence
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath
from typing import Any

import numpy as np

from .classifiers import (
    DEFAULT_CONFIDENCE_THRESHOLD,
    DEFAULT_MIN_SPREAD,
    DEFAULT_OOD_MULTIPLIER,
    DTWKNNClassifier,
    OODDetector,
    PrototypeClassifier,
)
from .features import (
    ENGINEERED_FEATURE_LENGTH,
    FEATURE_VERSION,
    RAW_FEATURE_LENGTH,
    SEQUENCE_LENGTH,
)
from .schema import IDENTIFIER_PATTERN, Profile
from .tensorflow_backend import export_keras_model_to_tfjs

BUNDLE_SCHEMA_VERSION = 1
MANIFEST_FILENAME = "manifest.json"
BASELINE_FILENAME = "baselines.npz"
EDGE_PROTOTYPE_FILENAME = "edge-prototype.json"
SUMMARY_FEATURE_LENGTH = ENGINEERED_FEATURE_LENGTH * 2
GESTURE_IDENTIFIER_PATTERN = IDENTIFIER_PATTERN
PROFILE_BINDING_MAGIC = b"fingerspeak-profile-binding-v1\0"


class BundleValidationError(ValueError):
    """Raised when a model manifest is unsafe or incompatible."""


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _artifact(path: Path, root: Path) -> dict[str, Any]:
    relative = path.relative_to(root).as_posix()
    return {"path": relative, "sha256": _sha256(path), "size": path.stat().st_size}


def _bundle_gesture_ids(profile: Profile) -> tuple[str, ...]:
    """Resolve the same stable gesture identifiers used by the web importer."""

    identifiers = tuple(
        "rest"
        if gesture.is_rest
        else (gesture.identifier or f"gesture-{index + 1}")
        for index, gesture in enumerate(profile.gestures)
    )
    if len(set(identifiers)) != len(identifiers):
        raise ValueError("profile gesture identifiers are not unique after Rest normalization")
    if any(GESTURE_IDENTIFIER_PATTERN.fullmatch(identifier) is None for identifier in identifiers):
        raise ValueError("profile contains a gesture identifier that is unsafe for a web bundle")
    return identifiers


def _uint32(value: int, label: str) -> bytes:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFF:
        raise ValueError(f"{label} must fit an unsigned 32-bit integer")
    return struct.pack("<I", value)


def _length_prefixed_utf8(value: str, label: str) -> bytes:
    if not isinstance(value, str):
        raise ValueError(f"{label} must be text")
    encoded = value.encode("utf-8")
    return _uint32(len(encoded), f"{label} UTF-8 byte length") + encoded


def canonical_profile_binding_bytes(profile: Profile) -> bytes:
    """Encode the cross-runtime v1 training-profile binding payload."""

    gesture_ids = _bundle_gesture_ids(profile)
    chunks = [PROFILE_BINDING_MAGIC, _uint32(len(profile.gestures), "gesture count")]
    for gesture_index, (gesture, gesture_id) in enumerate(
        zip(profile.gestures, gesture_ids, strict=True)
    ):
        label = f"gesture {gesture_index}"
        chunks.extend(
            (
                _length_prefixed_utf8(gesture_id, f"{label} id"),
                _length_prefixed_utf8(gesture.name, f"{label} name"),
                _length_prefixed_utf8(gesture.phrase, f"{label} phrase"),
                _length_prefixed_utf8(gesture.risk, f"{label} risk"),
                _uint32(gesture.dwell_ms, f"{label} dwell_ms"),
                _uint32(len(gesture.samples), f"{label} sample count"),
            )
        )
        for sample_index, sample in enumerate(gesture.samples):
            sample_label = f"{label} sample {sample_index}"
            raw = np.asarray(sample.raw, dtype="<f8", order="C")
            if raw.shape != (SEQUENCE_LENGTH, RAW_FEATURE_LENGTH):
                raise ValueError(
                    f"{sample_label} raw data must have shape "
                    f"({SEQUENCE_LENGTH}, {RAW_FEATURE_LENGTH})"
                )
            if not np.all(np.isfinite(raw)):
                raise ValueError(f"{sample_label} raw data must be finite")
            chunks.append(_length_prefixed_utf8(sample.session, f"{sample_label} session"))
            chunks.append(raw.tobytes(order="C"))
    return b"".join(chunks)


def training_profile_sha256(profile: Profile) -> str:
    """Hash the canonical model-binding bytes as lowercase SHA-256."""

    return hashlib.sha256(canonical_profile_binding_bytes(profile)).hexdigest()


def _write_json(path: Path, payload: Mapping[str, Any]) -> None:
    temporary_path = path.parent / f".{path.name}.tmp"
    temporary_path.write_text(
        json.dumps(payload, indent=2, sort_keys=True, allow_nan=False) + "\n",
        encoding="utf-8",
    )
    temporary_path.replace(path)


def _ensure_output_directory(path: Path, *, overwrite: bool) -> None:
    if path.exists() and not path.is_dir():
        raise FileExistsError(f"bundle output exists and is not a directory: {path}")
    if path.exists() and any(path.iterdir()) and not overwrite:
        raise FileExistsError(f"bundle output directory is not empty: {path}")
    path.mkdir(parents=True, exist_ok=True)


def write_model_bundle(
    output_directory: str | Path,
    *,
    profile: Profile,
    dtw: DTWKNNClassifier,
    prototype: PrototypeClassifier,
    ood: OODDetector,
    metrics: Mapping[str, Any] | None = None,
    keras_model: Any | None = None,
    overwrite: bool = False,
) -> Path:
    """Write portable baselines, optional TF.js weights, and a strict manifest."""

    if not dtw.sequences or prototype.centroids.size == 0 or ood.centroids.size == 0:
        raise ValueError("all baseline and OOD models must be fitted before export")
    if len(profile.gestures) != prototype.centroids.shape[0]:
        raise ValueError("profile class count does not match fitted prototypes")
    if not math.isclose(ood.multiplier, DEFAULT_OOD_MULTIPLIER, rel_tol=0.0, abs_tol=0.0):
        raise ValueError(
            f"edge bundles require OOD multiplier {DEFAULT_OOD_MULTIPLIER}, got {ood.multiplier}"
        )

    destination = Path(output_directory)
    _ensure_output_directory(destination, overwrite=overwrite)
    gesture_ids = _bundle_gesture_ids(profile)
    baseline_path = destination / BASELINE_FILENAME
    np.savez_compressed(
        baseline_path,
        dtw_sequences=np.stack(dtw.sequences),
        dtw_labels=dtw.labels,
        dtw_k=np.asarray([dtw.k], dtype=np.int64),
        prototype_centroids=prototype.centroids,
        prototype_spreads=prototype.spreads,
        ood_centroids=ood.centroids,
        ood_spreads=ood.spreads,
        ood_multiplier=np.asarray([ood.multiplier], dtype=np.float64),
    )

    edge_payload: dict[str, Any] = {
        "schema_version": BUNDLE_SCHEMA_VERSION,
        "feature": {
            "version": FEATURE_VERSION,
            "sequence_length": SEQUENCE_LENGTH,
            "feature_length": ENGINEERED_FEATURE_LENGTH,
            "summary_length": SUMMARY_FEATURE_LENGTH,
        },
        "confidence_threshold": DEFAULT_CONFIDENCE_THRESHOLD,
        "ood_multiplier": DEFAULT_OOD_MULTIPLIER,
        "prototypes": [
            {
                "gesture_id": gesture_id,
                "centroid": prototype.centroids[index].tolist(),
                "spread": float(prototype.spreads[index]),
            }
            for index, gesture_id in enumerate(gesture_ids)
        ],
    }
    validate_edge_prototype_artifact(edge_payload)
    _write_json(destination / EDGE_PROTOTYPE_FILENAME, edge_payload)

    models = [
        {"type": "dtw-knn", "artifact": BASELINE_FILENAME, "k": dtw.k},
        {"type": "nearest-prototype", "artifact": EDGE_PROTOTYPE_FILENAME},
    ]
    if keras_model is not None:
        export_keras_model_to_tfjs(keras_model, destination / "tfjs")
        models.insert(0, {"type": "bigru-24-v2", "artifact": "tfjs/model.json"})

    artifact_paths = sorted(
        path
        for path in destination.rglob("*")
        if path.is_file() and path.name != MANIFEST_FILENAME
    )
    manifest: dict[str, Any] = {
        "schema_version": BUNDLE_SCHEMA_VERSION,
        "created_at": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        "training_profile_sha256": training_profile_sha256(profile),
        "feature": {
            "version": FEATURE_VERSION,
            "sequence_length": SEQUENCE_LENGTH,
            "raw_feature_length": RAW_FEATURE_LENGTH,
            "engineered_feature_length": ENGINEERED_FEATURE_LENGTH,
        },
        "classes": [
            {
                "index": index,
                "gesture_id": gesture_ids[index],
                "name": gesture.name,
                "phrase": gesture.phrase,
                "icon": gesture.icon or "•",
                "is_rest": gesture.is_rest,
                "risk": gesture.risk,
                "confidence_threshold": DEFAULT_CONFIDENCE_THRESHOLD,
                "dwell_ms": gesture.dwell_ms,
            }
            for index, gesture in enumerate(profile.gestures)
        ],
        "models": models,
        "ood": {
            "type": "summary-centroid",
            "artifact": EDGE_PROTOTYPE_FILENAME,
            "multiplier": ood.multiplier,
        },
        "metrics": dict(metrics or {}),
        "artifacts": [_artifact(path, destination) for path in artifact_paths],
    }
    validate_model_manifest(manifest)
    manifest_path = destination / MANIFEST_FILENAME
    _write_json(manifest_path, manifest)
    return manifest_path


def validate_edge_prototype_artifact(payload: Any) -> dict[str, Any]:
    """Validate the small JSON artifact intended for direct browser import."""

    if not isinstance(payload, Mapping):
        raise BundleValidationError("edge prototype artifact must be an object")
    if payload.get("schema_version") != BUNDLE_SCHEMA_VERSION:
        raise BundleValidationError("unsupported edge prototype schema version")
    feature = payload.get("feature")
    expected_feature = {
        "version": FEATURE_VERSION,
        "sequence_length": SEQUENCE_LENGTH,
        "feature_length": ENGINEERED_FEATURE_LENGTH,
        "summary_length": SUMMARY_FEATURE_LENGTH,
    }
    if not isinstance(feature, Mapping) or any(
        feature.get(key) != value for key, value in expected_feature.items()
    ):
        raise BundleValidationError("edge prototype feature contract is incompatible")
    if payload.get("confidence_threshold") != DEFAULT_CONFIDENCE_THRESHOLD:
        raise BundleValidationError(
            f"edge confidence threshold must be {DEFAULT_CONFIDENCE_THRESHOLD}"
        )
    if payload.get("ood_multiplier") != DEFAULT_OOD_MULTIPLIER:
        raise BundleValidationError(f"edge OOD multiplier must be {DEFAULT_OOD_MULTIPLIER}")
    prototypes = payload.get("prototypes")
    if (
        not isinstance(prototypes, Sequence)
        or isinstance(prototypes, (str, bytes))
        or not 2 <= len(prototypes) <= 24
    ):
        raise BundleValidationError("edge prototypes must contain between two and 24 classes")
    identifiers: set[str] = set()
    for prototype in prototypes:
        if not isinstance(prototype, Mapping):
            raise BundleValidationError("edge prototype entries must be objects")
        identifier = prototype.get("gesture_id")
        if (
            not isinstance(identifier, str)
            or GESTURE_IDENTIFIER_PATTERN.fullmatch(identifier) is None
            or identifier in identifiers
        ):
            raise BundleValidationError("edge gesture identifiers must be safe and unique")
        identifiers.add(identifier)
        centroid = prototype.get("centroid")
        if (
            not isinstance(centroid, Sequence)
            or isinstance(centroid, (str, bytes))
            or len(centroid) != SUMMARY_FEATURE_LENGTH
            or any(
                isinstance(value, bool)
                or not isinstance(value, (int, float))
                or not math.isfinite(value)
                for value in centroid
            )
        ):
            raise BundleValidationError(
                f"edge centroids must contain {SUMMARY_FEATURE_LENGTH} finite numbers"
            )
        spread = prototype.get("spread")
        if (
            isinstance(spread, bool)
            or not isinstance(spread, (int, float))
            or not math.isfinite(spread)
            or spread < DEFAULT_MIN_SPREAD
        ):
            raise BundleValidationError(
                f"edge prototype spread must be at least {DEFAULT_MIN_SPREAD}"
            )
    return dict(payload)


def validate_model_manifest(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, Mapping):
        raise BundleValidationError("manifest must be an object")
    if payload.get("schema_version") != BUNDLE_SCHEMA_VERSION:
        raise BundleValidationError("unsupported bundle schema version")
    training_profile_digest = payload.get("training_profile_sha256")
    if (
        not isinstance(training_profile_digest, str)
        or len(training_profile_digest) != 64
        or any(character not in "0123456789abcdef" for character in training_profile_digest)
    ):
        raise BundleValidationError(
            "training_profile_sha256 must be a lowercase 64-character SHA-256 digest"
        )
    feature = payload.get("feature")
    if not isinstance(feature, Mapping):
        raise BundleValidationError("feature must be an object")
    expected = {
        "version": FEATURE_VERSION,
        "sequence_length": SEQUENCE_LENGTH,
        "raw_feature_length": RAW_FEATURE_LENGTH,
        "engineered_feature_length": ENGINEERED_FEATURE_LENGTH,
    }
    for key, expected_value in expected.items():
        if feature.get(key) != expected_value:
            raise BundleValidationError(
                f"feature.{key} is incompatible: {feature.get(key)!r}, expected {expected_value!r}"
            )

    classes = payload.get("classes")
    if (
        not isinstance(classes, Sequence)
        or isinstance(classes, (str, bytes))
        or not 2 <= len(classes) <= 24
    ):
        raise BundleValidationError("classes must contain between two and 24 entries")
    names: set[str] = set()
    gesture_ids: set[str] = set()
    rest_count = 0
    for index, value in enumerate(classes):
        if not isinstance(value, Mapping) or value.get("index") != index:
            raise BundleValidationError("classes must use contiguous ordered indices")
        name = value.get("name")
        if not isinstance(name, str) or not name.strip() or name.casefold() in names:
            raise BundleValidationError("class names must be non-empty and unique")
        names.add(name.casefold())
        gesture_id = value.get("gesture_id")
        if (
            not isinstance(gesture_id, str)
            or GESTURE_IDENTIFIER_PATTERN.fullmatch(gesture_id) is None
            or gesture_id in gesture_ids
        ):
            raise BundleValidationError("class gesture_id must be a safe unique identifier")
        gesture_ids.add(gesture_id)
        is_rest = value.get("is_rest")
        if not isinstance(is_rest, bool):
            raise BundleValidationError("class is_rest must be boolean")
        rest_count += int(is_rest)
        if is_rest != (gesture_id == "rest"):
            raise BundleValidationError("the Rest class must use gesture_id 'rest'")
        risk = value.get("risk")
        if risk not in {"routine", "clinical", "emergency"}:
            raise BundleValidationError("class risk must be routine, clinical, or emergency")
        threshold = value.get("confidence_threshold")
        dwell = value.get("dwell_ms")
        if threshold != DEFAULT_CONFIDENCE_THRESHOLD:
            raise BundleValidationError(
                f"confidence_threshold must be {DEFAULT_CONFIDENCE_THRESHOLD}"
            )
        if not isinstance(dwell, int) or isinstance(dwell, bool) or not 350 <= dwell <= 3000:
            raise BundleValidationError("dwell_ms must be an integer between 350 and 3000")
    if rest_count != 1:
        raise BundleValidationError("classes must contain exactly one Rest class")

    models = payload.get("models")
    if not isinstance(models, Sequence) or isinstance(models, (str, bytes)) or not models:
        raise BundleValidationError("models must contain at least one entry")
    model_artifacts: list[str] = []
    model_types: list[str] = []
    for model in models:
        if not isinstance(model, Mapping):
            raise BundleValidationError("model entries must be objects")
        model_type = model.get("type")
        artifact = model.get("artifact")
        if model_type not in {"nearest-prototype", "dtw-knn", "bigru-24-v2"}:
            raise BundleValidationError("model type is unsupported")
        if not isinstance(artifact, str):
            raise BundleValidationError("model artifact must be a string")
        model_types.append(model_type)
        model_artifacts.append(artifact)
    if model_types.count("nearest-prototype") != 1:
        raise BundleValidationError("models must contain exactly one nearest-prototype entry")
    nearest_index = model_types.index("nearest-prototype")
    if model_artifacts[nearest_index] != EDGE_PROTOTYPE_FILENAME:
        raise BundleValidationError(
            f"nearest-prototype must reference {EDGE_PROTOTYPE_FILENAME}"
        )

    ood = payload.get("ood")
    if not isinstance(ood, Mapping):
        raise BundleValidationError("ood must be an object")
    if (
        ood.get("type") != "summary-centroid"
        or ood.get("artifact") != EDGE_PROTOTYPE_FILENAME
        or ood.get("multiplier") != DEFAULT_OOD_MULTIPLIER
    ):
        raise BundleValidationError("ood contract is incompatible")
    if not isinstance(payload.get("metrics"), Mapping):
        raise BundleValidationError("metrics must be an object")

    artifacts = payload.get("artifacts")
    if (
        not isinstance(artifacts, Sequence)
        or isinstance(artifacts, (str, bytes))
        or len(artifacts) < 2
    ):
        raise BundleValidationError("artifacts must contain at least two entries")
    seen_paths: set[str] = set()
    for value in artifacts:
        if not isinstance(value, Mapping):
            raise BundleValidationError("artifact entries must be objects")
        relative = value.get("path")
        if not isinstance(relative, str):
            raise BundleValidationError("artifact path must be a string")
        pure_path = PurePosixPath(relative)
        if pure_path.is_absolute() or ".." in pure_path.parts or relative in seen_paths:
            raise BundleValidationError("artifact paths must be unique safe relative paths")
        seen_paths.add(relative)
        digest = value.get("sha256")
        if not isinstance(digest, str) or len(digest) != 64:
            raise BundleValidationError("artifact sha256 must be a 64-character digest")
        try:
            int(digest, 16)
        except ValueError as exc:
            raise BundleValidationError("artifact sha256 must be hexadecimal") from exc
        size = value.get("size")
        if not isinstance(size, int) or isinstance(size, bool) or size < 0:
            raise BundleValidationError("artifact size must be a non-negative integer")
    referenced_artifacts = set(model_artifacts) | {str(ood["artifact"])}
    if not referenced_artifacts.issubset(seen_paths):
        raise BundleValidationError("every model and OOD artifact must be checksummed")
    return dict(payload)


def load_model_manifest(
    path: str | Path,
    *,
    verify_artifacts: bool = True,
) -> dict[str, Any]:
    manifest_path = Path(path)
    try:
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise BundleValidationError(f"could not read manifest: {exc}") from exc
    manifest = validate_model_manifest(payload)
    if verify_artifacts:
        root = manifest_path.parent
        for artifact in manifest["artifacts"]:
            artifact_path = root / artifact["path"]
            if not artifact_path.is_file():
                raise BundleValidationError(f"missing artifact {artifact['path']!r}")
            if artifact_path.stat().st_size != artifact["size"]:
                raise BundleValidationError(f"artifact size mismatch for {artifact['path']!r}")
            if _sha256(artifact_path) != artifact["sha256"]:
                raise BundleValidationError(f"artifact checksum mismatch for {artifact['path']!r}")
        edge_path = root / EDGE_PROTOTYPE_FILENAME
        try:
            edge_payload = json.loads(edge_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise BundleValidationError(f"could not read edge prototype artifact: {exc}") from exc
        edge = validate_edge_prototype_artifact(edge_payload)
        manifest_ids = [entry["gesture_id"] for entry in manifest["classes"]]
        edge_ids = [entry["gesture_id"] for entry in edge["prototypes"]]
        if edge_ids != manifest_ids:
            raise BundleValidationError(
                "edge prototype order must match manifest class gesture IDs"
            )
    return manifest
