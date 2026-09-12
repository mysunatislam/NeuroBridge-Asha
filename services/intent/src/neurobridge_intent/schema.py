"""Shared feature and label schema.

Everything that crosses the Python <-> Dart boundary is pinned here: the per-frame
feature order, the window-statistic order, the command vocabulary, and the abnormal
movement classes. The Dart runtime in ``apps/mobile/lib/intent`` reads the exported
``manifest.json`` and refuses to load a bundle whose schema version differs.

Movement != command. Nothing in this module maps a single frame to an action.
"""

from __future__ import annotations

from enum import StrEnum

FRAME_SCHEMA_VERSION = "nb-intent-frame-v1"
WINDOW_SCHEMA_VERSION = "nb-intent-window-v1"
BUNDLE_SCHEMA_VERSION = "nb-intent-bundle-v1"
PROFILE_SCHEMA_VERSION = "neurobridge-patient-profile-v1"

#: Nominal analysis rate. Camera frames are resampled onto this grid.
FRAME_RATE_HZ = 20.0
#: Sliding window used by the intent and abnormal-movement classifiers (seconds).
WINDOW_SECONDS = 2.5
#: Sequence length consumed by the temporal model (seconds).
SEQUENCE_SECONDS = 3.0

WINDOW_FRAMES = int(round(WINDOW_SECONDS * FRAME_RATE_HZ))
SEQUENCE_FRAMES = int(round(SEQUENCE_SECONDS * FRAME_RATE_HZ))

#: Per-frame feature vector. Order is part of the contract.
FRAME_FEATURES: tuple[str, ...] = (
    # eyes
    "ear_left",
    "ear_right",
    "ear_mean",
    # mouth
    "mouth_open_ratio",
    "smile_ratio",
    "mouth_asymmetry",
    "lip_motion",
    # brows
    "brow_raise",
    # head pose (degrees) and angular speed (deg/s)
    "head_yaw",
    "head_pitch",
    "head_roll",
    "head_angular_speed",
    # face location in the frame (normalised 0..1) and scale
    "face_cx",
    "face_cy",
    "face_scale",
    # upper-limb gesture channel (0 when no hand/pose is tracked)
    "hand_present",
    "wrist_x",
    "wrist_y",
    "hand_speed",
    "hand_accel",
    "hand_direction",
    "elbow_angle",
    "shoulder_motion",
    # motion energy from optical flow (or a landmark-flow proxy on devices without it)
    "flow_mag_mean",
    "flow_mag_std",
    "flow_dir_consistency",
    "flow_dominant_hz",
    "flow_hf_ratio",
)
FRAME_FEATURE_COUNT = len(FRAME_FEATURES)
FRAME_INDEX = {name: index for index, name in enumerate(FRAME_FEATURES)}

#: Statistics computed per channel over a window, in this order.
CHANNEL_STATS: tuple[str, ...] = ("mean", "std", "min", "max", "range", "mean_abs_diff")

#: Window-level event features appended after the per-channel statistics.
EVENT_FEATURES: tuple[str, ...] = (
    "blink_count",
    "blink_mean_duration_ms",
    "blink_duration_cv",
    "blink_interval_cv",
    "blink_rate_hz",
    "head_dominant_hz",
    "head_rhythmicity",
    "face_jerk_rms",
    "face_smoothness",
    "hold_fraction",
    "direction_consistency",
    "onset_count",
    "peak_amplitude",
    "sustained_seconds",
)

WINDOW_FEATURES: tuple[str, ...] = (
    tuple(f"{channel}_{stat}" for channel in FRAME_FEATURES for stat in CHANNEL_STATS)
    + EVENT_FEATURES
)
WINDOW_FEATURE_COUNT = len(WINDOW_FEATURES)


class IntentClass(StrEnum):
    """Phase 1 classifier output. ``unknown`` is produced by the rejection gate."""

    intentional = "intentional"
    accidental = "accidental"
    unknown = "unknown"


INTENT_CLASSES: tuple[str, ...] = (IntentClass.intentional, IntentClass.accidental)


class CommandClass(StrEnum):
    """Temporal-model vocabulary. These are movement *patterns*, not phrases."""

    non_command = "non_command"
    triple_blink = "triple_blink"
    double_blink = "double_blink"
    long_blink = "long_blink"
    mouth_open_hold = "mouth_open_hold"
    smile_hold = "smile_hold"
    brow_raise_hold = "brow_raise_hold"
    head_left_hold = "head_left_hold"
    head_right_hold = "head_right_hold"
    hand_raise_hold = "hand_raise_hold"


COMMAND_CLASSES: tuple[str, ...] = tuple(item.value for item in CommandClass)


class AbnormalClass(StrEnum):
    normal_voluntary = "normal_voluntary"
    involuntary = "involuntary"
    possible_spasm = "possible_spasm"
    possible_seizure_like = "possible_seizure_like"


ABNORMAL_CLASSES: tuple[str, ...] = tuple(item.value for item in AbnormalClass)


class CalibrationPhase(StrEnum):
    """First-time setup recordings; each is 30 seconds by default."""

    normal_blinking = "normal_blinking"
    normal_facial_movement = "normal_facial_movement"
    intentional_gestures = "intentional_gestures"
    random_movement = "random_movement"
    rest_state = "rest_state"


CALIBRATION_PHASES: tuple[str, ...] = tuple(item.value for item in CalibrationPhase)
CALIBRATION_PHASE_SECONDS = 30.0

#: Default mapping from temporal command pattern to the app's patient signal kind.
DEFAULT_COMMAND_SIGNALS: dict[str, str] = {
    CommandClass.triple_blink: "rapidBlink",
    CommandClass.double_blink: "blink",
    CommandClass.long_blink: "slowBlink",
    CommandClass.mouth_open_hold: "mouthOpen",
    CommandClass.smile_hold: "smile",
    CommandClass.brow_raise_hold: "eyebrowsUp",
    CommandClass.head_left_hold: "headLeft",
    CommandClass.head_right_hold: "headRight",
    CommandClass.hand_raise_hold: "handRaised",
}

#: Confidence verification thresholds (fractions).
IGNORE_BELOW = 0.70
EXECUTE_AT = 0.90
