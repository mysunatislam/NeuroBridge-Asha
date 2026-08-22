from __future__ import annotations

import copy

import numpy as np
import pytest
from conftest import make_profile_payload

from fingerspeak_ml.dataset import all_sequences_by_class, session_aware_split
from fingerspeak_ml.schema import (
    ProfileValidationError,
    load_profile,
    profile_to_dict,
    validate_profile,
)


def test_valid_profile_round_trips(profile_payload: dict) -> None:
    profile_payload["gestures"][0]["samples"][0]["capturedAt"] = "legacy-free-form"
    profile = validate_profile(profile_payload, require_trainable=True)
    assert profile.class_names == ("Rest", "Yes")
    assert profile.gestures[0].is_rest
    assert profile.gestures[0].samples[0].raw.shape == (20, 63)
    assert profile.gestures[0].samples[0].captured_at is None
    reparsed = validate_profile(profile_to_dict(profile), require_trainable=True)
    assert reparsed.class_names == profile.class_names
    np.testing.assert_array_equal(
        reparsed.gestures[1].samples[0].raw,
        profile.gestures[1].samples[0].raw,
    )


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (lambda value: value.update(version=99), "unsupported profile version"),
        (
            lambda value: value["gestures"].append(copy.deepcopy(value["gestures"][0])),
            "duplicate gesture name",
        ),
        (
            lambda value: value["gestures"][0].update(phrase="speak during rest"),
            "Rest must not have",
        ),
        (
            lambda value: value["gestures"].__setitem__(
                slice(None), [value["gestures"][1]]
            ),
            "exactly one gesture named 'Rest'",
        ),
        (
            lambda value: value["gestures"][0]["samples"][0]["raw"].pop(),
            "exactly 20 frames",
        ),
        (
            lambda value: value["gestures"][0]["samples"][0]["raw"][0].pop(),
            "exactly 63 coordinates",
        ),
        (
            lambda value: value["gestures"][0]["samples"][0]["raw"][0].__setitem__(0, True),
            "must be a number",
        ),
        (
            lambda value: value["gestures"][0]["samples"][0]["raw"][0].__setitem__(0, 11.0),
            "between -10 and 10",
        ),
        (
            lambda value: value["gestures"][0]["samples"][0].update(session=""),
            "must not be empty",
        ),
    ],
)
def test_profile_validation_rejects_unsafe_payloads(
    copied_profile_payload: dict,
    mutate,
    message: str,
) -> None:
    mutate(copied_profile_payload)
    with pytest.raises(ProfileValidationError, match=message):
        validate_profile(copied_profile_payload)


def test_load_profile_reports_invalid_json(tmp_path) -> None:
    profile_path = tmp_path / "profile.json"
    profile_path.write_text("{not-json", encoding="utf-8")
    with pytest.raises(ProfileValidationError, match="could not read"):
        load_profile(profile_path)


def test_current_web_profile_version_is_supported(profile_v3_payload: dict) -> None:
    captured_at = "2026-08-15T09:30:45.123Z"
    profile_v3_payload.update(
        consentToEventSync=True,
        consentToCaregiverAlerts=True,
    )
    profile = validate_profile(profile_v3_payload, require_trainable=True)
    assert profile.version == 3
    assert profile.identifier == "local-profile"
    assert profile.gestures[1].risk == "clinical"
    assert profile.gestures[1].dwell_ms == 1000
    assert profile.consent_to_event_sync is True
    assert profile.consent_to_caregiver_alerts is True
    assert profile.consent_to_landmark_sync is False
    assert profile.gestures[1].samples[0].captured_at == captured_at
    serialized = profile_to_dict(profile)
    assert serialized["consentToEventSync"] is True
    assert serialized["consentToCaregiverAlerts"] is True
    assert serialized["consentToLandmarkSync"] is False
    assert serialized["gestures"][1]["samples"][0]["capturedAt"] == captured_at
    reparsed = validate_profile(serialized, require_trainable=True)
    assert reparsed.gestures[1].samples[0].captured_at == captured_at


def test_current_profile_accepts_json_integer_number_forms(
    profile_v3_payload: dict,
) -> None:
    profile_v3_payload["version"] = 3.0
    profile_v3_payload["gestures"][1]["dwellMs"] = 1000.0
    profile = validate_profile(profile_v3_payload)
    assert profile.version == 3
    assert profile.gestures[1].dwell_ms == 1000


def test_current_profile_rejects_invalid_captured_at(profile_v3_payload: dict) -> None:
    profile_v3_payload["gestures"][0]["samples"][0]["capturedAt"] = "not-a-date-time"

    with pytest.raises(ProfileValidationError, match="RFC 3339 date-time"):
        validate_profile(profile_v3_payload, require_trainable=True)


def test_short_key_identifiers_allow_dots_and_require_alphanumeric_prefix(
    profile_v3_payload: dict,
) -> None:
    profile_v3_payload["id"] = "profile.v3"
    profile_v3_payload["gestures"][1]["id"] = "yes.custom-v1"

    profile = validate_profile(profile_v3_payload, require_trainable=True)
    assert profile.identifier == "profile.v3"
    assert [gesture.identifier for gesture in profile.gestures] == [
        "rest",
        "yes.custom-v1",
    ]

    for invalid in (".leading-dot", "-leading-hyphen", "_leading-underscore"):
        profile_v3_payload["gestures"][1]["id"] = invalid
        with pytest.raises(ProfileValidationError, match="must match"):
            validate_profile(profile_v3_payload, require_trainable=True)


@pytest.mark.parametrize("field", ["id", "name", "updatedAt", "gestures"])
def test_current_profile_requires_root_fields(
    profile_v3_payload: dict,
    field: str,
) -> None:
    profile_v3_payload.pop(field)
    with pytest.raises(ProfileValidationError):
        validate_profile(profile_v3_payload)


@pytest.mark.parametrize(
    "field",
    ["id", "name", "phrase", "icon", "risk", "dwellMs", "samples"],
)
def test_current_profile_requires_gesture_fields(
    profile_v3_payload: dict,
    field: str,
) -> None:
    profile_v3_payload["gestures"][1].pop(field)
    with pytest.raises(ProfileValidationError, match="is required"):
        validate_profile(profile_v3_payload)


@pytest.mark.parametrize("field", ["raw", "session"])
def test_current_profile_requires_sample_fields(
    profile_v3_payload: dict,
    field: str,
) -> None:
    profile_v3_payload["gestures"][1]["samples"][0].pop(field)
    with pytest.raises(ProfileValidationError, match="is required"):
        validate_profile(profile_v3_payload)


@pytest.mark.parametrize("scope", ["profile", "gesture", "sample"])
def test_current_profile_rejects_additional_properties(
    profile_v3_payload: dict,
    scope: str,
) -> None:
    target = profile_v3_payload
    if scope == "gesture":
        target = profile_v3_payload["gestures"][1]
    elif scope == "sample":
        target = profile_v3_payload["gestures"][1]["samples"][0]
    target["unexpected"] = "legacy-only"

    with pytest.raises(ProfileValidationError, match="unsupported field"):
        validate_profile(profile_v3_payload)


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("id", "g_rest"),
        ("name", "rest"),
        ("phrase", "do not speak"),
        ("protected", False),
    ],
)
def test_current_profile_enforces_exact_rest_policy(
    profile_v3_payload: dict,
    field: str,
    value,
) -> None:
    profile_v3_payload["gestures"][0][field] = value
    with pytest.raises(ProfileValidationError, match="exactly one Rest"):
        validate_profile(profile_v3_payload)


def test_current_profile_requires_two_gestures_without_training_mode(
    profile_v3_payload: dict,
) -> None:
    profile_v3_payload["gestures"].pop()
    with pytest.raises(ProfileValidationError, match="at least 2"):
        validate_profile(profile_v3_payload, require_trainable=False)


def test_current_profile_rejects_legacy_sample_array(profile_v3_payload: dict) -> None:
    sample = profile_v3_payload["gestures"][1]["samples"][0]
    profile_v3_payload["gestures"][1]["samples"][0] = sample["raw"]
    with pytest.raises(ProfileValidationError, match="must be an object"):
        validate_profile(profile_v3_payload)


def test_legacy_profile_converts_raw_array_sample(profile_payload: dict) -> None:
    sample = profile_payload["gestures"][1]["samples"][0]
    profile_payload["gestures"][1]["samples"][0] = sample["raw"]
    profile = validate_profile(profile_payload, require_trainable=True)
    assert profile.gestures[1].samples[0].session == "imported"


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (lambda value: value["gestures"][0]["samples"][0]["raw"].pop(), "20 frames"),
        (
            lambda value: value["gestures"][0]["samples"][0]["raw"][0].pop(),
            "63 coordinates",
        ),
        (
            lambda value: value["gestures"][0]["samples"][0]["raw"][0].__setitem__(
                0, 10.01
            ),
            "between -10 and 10",
        ),
        (
            lambda value: value["gestures"][0]["samples"][0].update(session=".bad"),
            "must match",
        ),
        (
            lambda value: value.update(updatedAt="2026-08-15 10:00:00"),
            "RFC 3339",
        ),
        (
            lambda value: value["gestures"][0]["samples"][0].update(
                capturedAt=None
            ),
            "RFC 3339",
        ),
        (
            lambda value: value.update(consentToLandmarkSync=True),
            "must be false",
        ),
    ],
)
def test_current_profile_rejects_contract_drift(
    profile_v3_payload: dict,
    mutate,
    message: str,
) -> None:
    mutate(profile_v3_payload)
    with pytest.raises(ProfileValidationError, match=message):
        validate_profile(profile_v3_payload)


def test_session_aware_split_holds_out_a_complete_session(profile_payload: dict) -> None:
    profile = validate_profile(profile_payload, require_trainable=True)
    split = session_aware_split(profile, seed=10)
    assert split.all_session_based
    assert split.held_out_sessions == ("s1", "s1")
    assert split.train_x.shape == (4, 20, 98)
    assert split.validation_x.shape == (4, 20, 98)
    assert split.train_y.tolist() == [0, 0, 1, 1]
    assert split.validation_y.tolist() == [0, 0, 1, 1]


def test_same_session_split_is_labeled_and_deterministic() -> None:
    payload = make_profile_payload(sessions=("only", "only"))
    profile = validate_profile(payload, require_trainable=True)
    first = session_aware_split(profile, seed=42)
    second = session_aware_split(profile, seed=42)
    assert not first.all_session_based
    assert first.held_out_sessions == (None, None)
    np.testing.assert_array_equal(first.train_x, second.train_x)
    np.testing.assert_array_equal(first.validation_x, second.validation_x)


def test_all_sequences_by_class_preserves_class_and_sample_counts(profile_payload: dict) -> None:
    profile = validate_profile(profile_payload, require_trainable=True)
    sequences = all_sequences_by_class(profile)
    assert tuple(len(class_sequences) for class_sequences in sequences) == (4, 4)
    assert all(sequence.shape == (20, 98) for group in sequences for sequence in group)
