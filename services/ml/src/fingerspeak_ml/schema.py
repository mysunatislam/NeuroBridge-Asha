"""Validation for FingerSpeak profile JSON and raw calibration samples."""

from __future__ import annotations

import json
import math
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime
from numbers import Real
from pathlib import Path
from typing import Any

import numpy as np
from numpy.typing import NDArray

from .features import RAW_FEATURE_LENGTH, SEQUENCE_LENGTH

PROFILE_VERSION = 3
SUPPORTED_PROFILE_VERSIONS = (2, PROFILE_VERSION)
MAX_PROFILE_BYTES = 64 * 1024 * 1024
MAX_GESTURES = 24
MAX_SAMPLES_PER_GESTURE = 48
MAX_NAME_LENGTH = 48
MAX_PHRASE_LENGTH = 240
MAX_PROFILE_NAME_LENGTH = 80
MAX_SESSION_ID_LENGTH = 80
IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$")
DATE_TIME_PATTERN = re.compile(
    r"^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:\d{2})$"
)
RISK_LEVELS = ("routine", "clinical", "emergency")
PROFILE_V3_KEYS = frozenset(
    {
        "version",
        "id",
        "name",
        "consentToEventSync",
        "consentToCaregiverAlerts",
        "consentToLandmarkSync",
        "updatedAt",
        "gestures",
    }
)
GESTURE_V3_KEYS = frozenset(
    {"id", "name", "phrase", "icon", "protected", "risk", "dwellMs", "samples"}
)
SAMPLE_V3_KEYS = frozenset({"session", "capturedAt", "raw"})

FloatArray = NDArray[np.float64]


class ProfileValidationError(ValueError):
    """Raised when imported calibration data violates the profile contract."""


@dataclass(frozen=True, slots=True)
class CalibrationSample:
    raw: FloatArray
    session: str
    captured_at: str | None = None


@dataclass(frozen=True, slots=True)
class Gesture:
    name: str
    phrase: str
    samples: tuple[CalibrationSample, ...]
    identifier: str | None = None
    icon: str | None = None
    protected: bool = False
    risk: str = "routine"
    dwell_ms: int = 650

    @property
    def is_rest(self) -> bool:
        return self.name.casefold() == "rest"


@dataclass(frozen=True, slots=True)
class Profile:
    version: int
    gestures: tuple[Gesture, ...]
    identifier: str | None = None
    name: str | None = None
    consent_to_event_sync: bool = False
    consent_to_caregiver_alerts: bool = False
    consent_to_landmark_sync: bool = False
    updated_at: str | None = None

    @property
    def class_names(self) -> tuple[str, ...]:
        return tuple(gesture.name for gesture in self.gestures)


def _fail(path: str, message: str) -> ProfileValidationError:
    return ProfileValidationError(f"{path}: {message}")


def _mapping(value: Any, path: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise _fail(path, "must be an object")
    return value


def _list(value: Any, path: str) -> Sequence[Any]:
    if not isinstance(value, Sequence) or isinstance(value, (str, bytes, bytearray)):
        raise _fail(path, "must be an array")
    return value


def _string(
    value: Any,
    path: str,
    *,
    maximum: int,
    allow_empty: bool = False,
) -> str:
    if not isinstance(value, str):
        raise _fail(path, "must be a string")
    normalized = value.strip()
    if not normalized and not allow_empty:
        raise _fail(path, "must not be empty")
    if len(value) > maximum:
        raise _fail(path, f"must contain at most {maximum} characters")
    return value


def _optional_string(value: Any, path: str, *, maximum: int) -> str | None:
    if value is None:
        return None
    return _string(value, path, maximum=maximum, allow_empty=True)


def _schema_string(
    value: Any,
    path: str,
    *,
    minimum: int = 0,
    maximum: int,
) -> str:
    """Validate JSON Schema string length without legacy trimming/normalization."""

    if not isinstance(value, str):
        raise _fail(path, "must be a string")
    if len(value) < minimum:
        raise _fail(path, f"must contain at least {minimum} character(s)")
    if len(value) > maximum:
        raise _fail(path, f"must contain at most {maximum} characters")
    return value


def _required(item: Mapping[str, Any], key: str, path: str) -> Any:
    if key not in item:
        raise _fail(f"{path}.{key}", "is required")
    return item[key]


def _reject_extra_fields(
    item: Mapping[str, Any],
    allowed: frozenset[str],
    path: str,
) -> None:
    extras = sorted(str(key) for key in item if key not in allowed)
    if extras:
        raise _fail(path, f"contains unsupported field(s): {', '.join(extras)}")


def _optional_date_time(value: Any, path: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise _fail(path, "must be a valid RFC 3339 date-time")
    text = value
    if DATE_TIME_PATTERN.fullmatch(text) is None:
        raise _fail(path, "must be a valid RFC 3339 date-time")
    iso_text = f"{text[:-1]}+00:00" if text[-1] in "Zz" else text
    try:
        parsed = datetime.fromisoformat(iso_text)
    except ValueError as exc:
        raise _fail(path, "must be a valid RFC 3339 date-time") from exc
    if parsed.tzinfo is None:
        raise _fail(path, "must include a UTC offset")
    return text


def _required_date_time(item: Mapping[str, Any], key: str, path: str) -> str:
    value = _required(item, key, path)
    parsed = _optional_date_time(value, f"{path}.{key}")
    if parsed is None:
        raise _fail(f"{path}.{key}", "must be a valid RFC 3339 date-time")
    return parsed


def _raw_sequence(value: Any, path: str) -> FloatArray:
    frames = _list(value, path)
    if len(frames) != SEQUENCE_LENGTH:
        raise _fail(path, f"must contain exactly {SEQUENCE_LENGTH} frames")
    output = np.empty((SEQUENCE_LENGTH, RAW_FEATURE_LENGTH), dtype=np.float64)
    for frame_index, frame_value in enumerate(frames):
        frame_path = f"{path}[{frame_index}]"
        frame = _list(frame_value, frame_path)
        if len(frame) != RAW_FEATURE_LENGTH:
            raise _fail(frame_path, f"must contain exactly {RAW_FEATURE_LENGTH} coordinates")
        for coordinate_index, coordinate in enumerate(frame):
            coordinate_path = f"{frame_path}[{coordinate_index}]"
            if isinstance(coordinate, bool) or not isinstance(coordinate, Real):
                raise _fail(coordinate_path, "must be a number")
            number = float(coordinate)
            if not math.isfinite(number):
                raise _fail(coordinate_path, "must be finite")
            if abs(number) > 10.0:
                raise _fail(coordinate_path, "must be between -10 and 10")
            output[frame_index, coordinate_index] = number
    return output


def _json_integer(value: Any, path: str) -> int:
    if isinstance(value, bool) or not isinstance(value, Real):
        raise _fail(path, "must be an integer")
    try:
        number = float(value)
    except (OverflowError, ValueError) as exc:
        raise _fail(path, "must be an integer") from exc
    if not math.isfinite(number) or not number.is_integer():
        raise _fail(path, "must be an integer")
    return int(number)


def _identifier(value: Any, path: str, *, required: bool) -> str | None:
    if value is None and not required:
        return None
    if not isinstance(value, str) or IDENTIFIER_PATTERN.fullmatch(value) is None:
        raise _fail(path, "must match ^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$")
    return value


def _default_dwell(risk: str) -> int:
    if risk == "emergency":
        return 1500
    if risk == "clinical":
        return 1000
    return 650


def validate_profile(payload: Any, *, require_trainable: bool = False) -> Profile:
    """Validate and normalize a legacy-v2 or current-v3 profile payload.

    Validation is deliberately strict at this trust boundary: dimensions are
    fixed, all coordinates must be finite JSON numbers, class names are unique,
    and exactly one non-speaking ``Rest`` class must exist.
    """

    root = _mapping(payload, "$")
    version = _json_integer(_required(root, "version", "$"), "$.version")
    if version not in SUPPORTED_PROFILE_VERSIONS:
        raise _fail(
            "$.version",
            f"unsupported profile version {version!r}; "
            f"expected one of {SUPPORTED_PROFILE_VERSIONS}",
        )

    is_current = version == PROFILE_VERSION
    if is_current:
        _reject_extra_fields(root, PROFILE_V3_KEYS, "$")
        profile_identifier = _identifier(
            _required(root, "id", "$"),
            "$.id",
            required=True,
        )
        profile_name = _schema_string(
            _required(root, "name", "$"),
            "$.name",
            minimum=1,
            maximum=MAX_PROFILE_NAME_LENGTH,
        )
        event_consent = root.get("consentToEventSync", False)
        if not isinstance(event_consent, bool):
            raise _fail("$.consentToEventSync", "must be a boolean")
        caregiver_consent = root.get("consentToCaregiverAlerts", False)
        if not isinstance(caregiver_consent, bool):
            raise _fail("$.consentToCaregiverAlerts", "must be a boolean")
        landmark_consent = root.get("consentToLandmarkSync", False)
        if landmark_consent is not False:
            raise _fail("$.consentToLandmarkSync", "must be false")
        updated_at = _required_date_time(root, "updatedAt", "$")
    else:
        profile_identifier = _identifier(root.get("id"), "$.id", required=False)
        profile_name = _optional_string(
            root.get("name"),
            "$.name",
            maximum=MAX_PROFILE_NAME_LENGTH,
        )
        event_consent = root.get("consentToEventSync", False)
        if not isinstance(event_consent, bool):
            raise _fail("$.consentToEventSync", "must be a boolean")
        caregiver_consent = root.get("consentToCaregiverAlerts", False)
        if not isinstance(caregiver_consent, bool):
            raise _fail("$.consentToCaregiverAlerts", "must be a boolean")
        landmark_consent = root.get("consentToLandmarkSync", False)
        if not isinstance(landmark_consent, bool):
            raise _fail("$.consentToLandmarkSync", "must be a boolean")
        updated_at = _optional_string(root.get("updatedAt"), "$.updatedAt", maximum=64)

    gesture_payload = (
        _required(root, "gestures", "$") if is_current else root.get("gestures")
    )
    gesture_values = _list(gesture_payload, "$.gestures")
    minimum_gestures = 2 if is_current else 1
    if len(gesture_values) < minimum_gestures:
        message = (
            "must contain at least 2 gestures"
            if is_current
            else "must contain at least one gesture"
        )
        raise _fail("$.gestures", message)
    if len(gesture_values) > MAX_GESTURES:
        raise _fail("$.gestures", f"must contain at most {MAX_GESTURES} gestures")

    gestures: list[Gesture] = []
    seen_names: set[str] = set()
    seen_identifiers: set[str] = set()
    for gesture_index, gesture_value in enumerate(gesture_values):
        path = f"$.gestures[{gesture_index}]"
        item = _mapping(gesture_value, path)
        if is_current:
            _reject_extra_fields(item, GESTURE_V3_KEYS, path)
            name = _schema_string(
                _required(item, "name", path),
                f"{path}.name",
                minimum=1,
                maximum=MAX_NAME_LENGTH,
            )
            phrase = _schema_string(
                _required(item, "phrase", path),
                f"{path}.phrase",
                maximum=MAX_PHRASE_LENGTH,
            )
            identifier = _identifier(
                _required(item, "id", path),
                f"{path}.id",
                required=True,
            )
            icon = _schema_string(
                _required(item, "icon", path),
                f"{path}.icon",
                maximum=8,
            )
            protected = item.get("protected", False)
            if not isinstance(protected, bool):
                raise _fail(f"{path}.protected", "must be a boolean")
            risk = _required(item, "risk", path)
            if not isinstance(risk, str) or risk not in RISK_LEVELS:
                raise _fail(f"{path}.risk", f"must be one of {', '.join(RISK_LEVELS)}")
            dwell_ms = _required(item, "dwellMs", path)
            sample_values = _list(
                _required(item, "samples", path),
                f"{path}.samples",
            )
        else:
            name = _string(item.get("name"), f"{path}.name", maximum=MAX_NAME_LENGTH)
            phrase = _string(
                item.get("phrase", ""),
                f"{path}.phrase",
                maximum=MAX_PHRASE_LENGTH,
                allow_empty=True,
            )
            identifier = _identifier(item.get("id"), f"{path}.id", required=False)
            icon = _optional_string(item.get("icon"), f"{path}.icon", maximum=8)
            protected = item.get("protected", False)
            if not isinstance(protected, bool):
                raise _fail(f"{path}.protected", "must be a boolean")
            risk = item.get("risk", "routine")
            if not isinstance(risk, str) or risk not in RISK_LEVELS:
                raise _fail(f"{path}.risk", f"must be one of {', '.join(RISK_LEVELS)}")
            dwell_ms = item.get("dwellMs", _default_dwell(risk))
            sample_values = _list(item.get("samples", []), f"{path}.samples")

        folded_name = name.casefold()
        if folded_name in seen_names:
            raise _fail(f"{path}.name", f"duplicate gesture name {name!r}")
        seen_names.add(folded_name)

        if identifier:
            if identifier in seen_identifiers:
                raise _fail(f"{path}.id", f"duplicate gesture id {identifier!r}")
            seen_identifiers.add(identifier)
        try:
            dwell_ms = _json_integer(dwell_ms, f"{path}.dwellMs")
        except ProfileValidationError as exc:
            raise _fail(
                f"{path}.dwellMs",
                "must be an integer between 350 and 3000",
            ) from exc
        if not 350 <= dwell_ms <= 3000:
            raise _fail(f"{path}.dwellMs", "must be an integer between 350 and 3000")

        if len(sample_values) > MAX_SAMPLES_PER_GESTURE:
            raise _fail(
                f"{path}.samples",
                f"must contain at most {MAX_SAMPLES_PER_GESTURE} samples",
            )
        samples: list[CalibrationSample] = []
        for sample_index, sample_value in enumerate(sample_values):
            sample_path = f"{path}.samples[{sample_index}]"
            if is_current:
                sample_item = _mapping(sample_value, sample_path)
                _reject_extra_fields(sample_item, SAMPLE_V3_KEYS, sample_path)
                session = _identifier(
                    _required(sample_item, "session", sample_path),
                    f"{sample_path}.session",
                    required=True,
                )
                assert session is not None
                if "capturedAt" in sample_item:
                    captured_at = _optional_date_time(
                        sample_item["capturedAt"],
                        f"{sample_path}.capturedAt",
                    )
                    if captured_at is None:
                        raise _fail(
                            f"{sample_path}.capturedAt",
                            "must be a valid RFC 3339 date-time",
                        )
                else:
                    captured_at = None
                raw_value = _required(sample_item, "raw", sample_path)
            elif isinstance(sample_value, Mapping):
                sample_item = sample_value
                session = _string(
                    sample_item.get("session", "imported"),
                    f"{sample_path}.session",
                    maximum=MAX_SESSION_ID_LENGTH,
                )
                captured_at = None
                raw_value = sample_item.get("raw")
            else:
                session = "imported"
                captured_at = None
                raw_value = sample_value
            raw = _raw_sequence(raw_value, f"{sample_path}.raw")
            samples.append(
                CalibrationSample(raw=raw, session=session, captured_at=captured_at)
            )

        gesture = Gesture(
            identifier=identifier,
            name=name,
            phrase=phrase,
            icon=icon,
            protected=protected,
            risk=risk,
            dwell_ms=dwell_ms,
            samples=tuple(samples),
        )
        if not is_current and gesture.is_rest and phrase.strip():
            raise _fail(f"{path}.phrase", "Rest must not have a spoken phrase")
        gestures.append(gesture)

    if is_current:
        exact_rests = [
            gesture
            for gesture in gestures
            if gesture.identifier == "rest"
            and gesture.name == "Rest"
            and gesture.phrase == ""
            and gesture.protected
        ]
        if len(exact_rests) != 1:
            raise _fail(
                "$.gestures",
                "must contain exactly one Rest with id 'rest', name 'Rest', "
                "an empty phrase, and protected true",
            )
    else:
        rest_count = sum(gesture.is_rest for gesture in gestures)
        if rest_count != 1:
            raise _fail("$.gestures", "must contain exactly one gesture named 'Rest'")
        rest = next(gesture for gesture in gestures if gesture.is_rest)
        if not rest.protected:
            raise _fail("$.gestures", "Rest must be protected")
    if require_trainable:
        if len(gestures) < 2:
            raise _fail("$.gestures", "training requires Rest plus at least one speaking gesture")
        empty = [gesture.name for gesture in gestures if not gesture.samples]
        if empty:
            raise _fail(
                "$.gestures",
                f"training requires samples for every gesture: {', '.join(empty)}",
            )
    return Profile(
        version=version,
        gestures=tuple(gestures),
        identifier=profile_identifier,
        name=profile_name,
        consent_to_event_sync=event_consent,
        consent_to_caregiver_alerts=caregiver_consent,
        # Importing a profile never opts this device into uploading biometric
        # landmark samples. A future explicit consent ceremony must own that
        # transition; the ML package intentionally has no upload operation.
        consent_to_landmark_sync=False,
        updated_at=updated_at,
    )


def load_profile(path: str | Path, *, require_trainable: bool = False) -> Profile:
    """Load a size-limited UTF-8 JSON profile from disk and validate it."""

    profile_path = Path(path)
    try:
        size = profile_path.stat().st_size
    except OSError as exc:
        raise ProfileValidationError(f"could not access profile {profile_path}: {exc}") from exc
    if size > MAX_PROFILE_BYTES:
        raise ProfileValidationError(
            f"profile is {size} bytes; maximum accepted size is {MAX_PROFILE_BYTES}"
        )
    try:
        payload = json.loads(profile_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ProfileValidationError(f"could not read profile {profile_path}: {exc}") from exc
    return validate_profile(payload, require_trainable=require_trainable)


def profile_to_dict(profile: Profile) -> dict[str, Any]:
    """Return a JSON-safe representation of a validated profile."""

    gestures: list[dict[str, Any]] = []
    for gesture in profile.gestures:
        samples: list[dict[str, Any]] = []
        for sample in gesture.samples:
            sample_item: dict[str, Any] = {
                "session": sample.session,
                "raw": sample.raw.tolist(),
            }
            if profile.version == PROFILE_VERSION and sample.captured_at is not None:
                sample_item["capturedAt"] = sample.captured_at
            samples.append(sample_item)
        item: dict[str, Any] = {
            "name": gesture.name,
            "phrase": gesture.phrase,
            "risk": gesture.risk,
            "dwellMs": gesture.dwell_ms,
            "samples": samples,
        }
        if gesture.identifier is not None:
            item["id"] = gesture.identifier
        if gesture.icon is not None:
            item["icon"] = gesture.icon
        if gesture.protected:
            item["protected"] = True
        gestures.append(item)
    result: dict[str, Any] = {"version": profile.version, "gestures": gestures}
    if profile.identifier is not None:
        result["id"] = profile.identifier
    if profile.name is not None:
        result["name"] = profile.name
    if profile.version == PROFILE_VERSION:
        result["consentToEventSync"] = profile.consent_to_event_sync
        result["consentToCaregiverAlerts"] = profile.consent_to_caregiver_alerts
        result["consentToLandmarkSync"] = False
    if profile.updated_at is not None:
        result["updatedAt"] = profile.updated_at
    return result
