"""Patient calibration: five 30-second recordings -> ``patient_profile.json``.

The profile stores the patient's *own* blink pattern, movement range, baseline
facial activity, involuntary-motion profile, per-channel normalisers and
window-feature prototypes for the intentional / random / rest phases. Every later
stage reads it: the temporal model normalises with it, the intent classifier is
blended with the prototype classifier, and the verification engine takes its
thresholds from it.
"""

from __future__ import annotations

import json
import math
from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import numpy as np
from numpy.typing import NDArray

from .features.blink import blink_statistics
from .features.window import FrameFeatures, detect_blinks, window_features
from .schema import (
    CALIBRATION_PHASE_SECONDS,
    CALIBRATION_PHASES,
    EXECUTE_AT,
    FRAME_FEATURE_COUNT,
    FRAME_FEATURES,
    FRAME_INDEX,
    FRAME_RATE_HZ,
    IGNORE_BELOW,
    PROFILE_SCHEMA_VERSION,
    WINDOW_FEATURE_COUNT,
    WINDOW_FRAMES,
    CalibrationPhase,
    CommandClass,
)

FloatArray = NDArray[np.float64]

MIN_PHASE_SECONDS = 10.0
RANGE_CHANNELS = (
    "ear_mean",
    "mouth_open_ratio",
    "smile_ratio",
    "brow_raise",
    "head_yaw",
    "head_pitch",
    "head_roll",
    "head_angular_speed",
    "hand_speed",
    "flow_mag_mean",
)


class CalibrationError(ValueError):
    pass


@dataclass(slots=True)
class PhaseRecording:
    phase: str
    frames: list[FrameFeatures] = field(default_factory=list)

    @property
    def seconds(self) -> float:
        if len(self.frames) < 2:
            return 0.0
        return self.frames[-1].t_s - self.frames[0].t_s

    def matrix(self) -> FloatArray:
        return np.stack([frame.values for frame in self.frames])

    def timestamps(self) -> FloatArray:
        return np.asarray([frame.t_s for frame in self.frames])


@dataclass(slots=True)
class PatientProfile:
    patient_id: str
    created_at: str
    phases: dict[str, dict[str, float]]
    blink: dict[str, float]
    movement_range: dict[str, list[float]]
    baseline_facial_activity: dict[str, Any]
    involuntary_profile: dict[str, float]
    gesture_thresholds: dict[str, Any]
    normalizer: dict[str, list[float]]
    prototypes: dict[str, dict[str, list[float]]]
    command_map: dict[str, str]
    schema_version: str = PROFILE_SCHEMA_VERSION
    feature_schema: str = "nb-intent-frame-v1"
    notes: str = "Baseline measured from the patient's own recordings; not a diagnosis."

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "feature_schema": self.feature_schema,
            "patient_id": self.patient_id,
            "created_at": self.created_at,
            "phases": self.phases,
            "blink": self.blink,
            "movement_range": self.movement_range,
            "baseline_facial_activity": self.baseline_facial_activity,
            "involuntary_profile": self.involuntary_profile,
            "gesture_thresholds": self.gesture_thresholds,
            "normalizer": self.normalizer,
            "prototypes": self.prototypes,
            "command_map": self.command_map,
            "notes": self.notes,
        }

    def save(self, path: str | Path) -> Path:
        target = Path(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(self.to_dict(), indent=2, allow_nan=False), encoding="utf-8")
        return target

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> PatientProfile:
        if data.get("schema_version") != PROFILE_SCHEMA_VERSION:
            raise CalibrationError("unsupported patient profile schema")
        normalizer = data["normalizer"]
        if (
            len(normalizer["mean"]) != FRAME_FEATURE_COUNT
            or len(normalizer["std"]) != FRAME_FEATURE_COUNT
        ):
            raise CalibrationError("normalizer length does not match the frame schema")
        return cls(
            patient_id=str(data["patient_id"]),
            created_at=str(data["created_at"]),
            phases=dict(data.get("phases", {})),
            blink=dict(data["blink"]),
            movement_range=dict(data["movement_range"]),
            baseline_facial_activity=dict(data["baseline_facial_activity"]),
            involuntary_profile=dict(data.get("involuntary_profile", {})),
            gesture_thresholds=dict(data["gesture_thresholds"]),
            normalizer={"mean": list(normalizer["mean"]), "std": list(normalizer["std"])},
            prototypes={k: dict(v) for k, v in data.get("prototypes", {}).items()},
            command_map=dict(data.get("command_map", {})),
            notes=str(data.get("notes", "")),
        )

    @classmethod
    def load(cls, path: str | Path) -> PatientProfile:
        return cls.from_dict(json.loads(Path(path).read_text(encoding="utf-8")))

    @classmethod
    def default(cls, patient_id: str = "default") -> PatientProfile:
        """Population defaults used before a patient has been calibrated."""

        from .synthetic import generate_calibration_phase

        rng = np.random.default_rng(0)
        session = CalibrationSession(patient_id=patient_id, phase_seconds=12.0)
        for phase in CalibrationPhase:
            clip = generate_calibration_phase(rng, phase, seconds=12.0)
            session.add_frames(
                phase,
                (
                    FrameFeatures(float(t), row)
                    for t, row in zip(clip.timestamps, clip.values, strict=False)
                ),
            )
        profile = session.build_profile()
        profile.notes = "Population default profile; replace it by running patient calibration."
        return profile

    # -- helpers used by the runtime ------------------------------------------------

    def normalize(self, matrix: FloatArray) -> FloatArray:
        mean = np.asarray(self.normalizer["mean"])
        std = np.asarray(self.normalizer["std"])
        return (np.asarray(matrix, dtype=np.float64) - mean) / std

    def open_ear(self) -> float:
        return float(self.blink.get("open_ear", 0.30))

    def prototype_scores(self, window_vector: FloatArray) -> dict[str, float]:
        """Inverse-distance similarity of a window vector to each phase prototype."""

        scores: dict[str, float] = {}
        for name, proto in self.prototypes.items():
            centre = np.asarray(proto["mean"])
            spread = np.asarray(proto["std"])
            z = (np.asarray(window_vector) - centre) / spread
            distance = float(np.sqrt(np.mean(z**2)))
            scores[name] = 1.0 / (1.0 + distance)
        return scores

    def intentional_prototype_probability(self, window_vector: FloatArray) -> float:
        scores = self.prototype_scores(window_vector)
        if not scores:
            return 0.5
        intentional = scores.get(CalibrationPhase.intentional_gestures, 0.0)
        others = [v for k, v in scores.items() if k != CalibrationPhase.intentional_gestures]
        denominator = intentional + (max(others) if others else 0.0)
        return intentional / denominator if denominator > 0 else 0.5


class CalibrationSession:
    """Collects the five phase recordings and builds a :class:`PatientProfile`."""

    def __init__(
        self, *, patient_id: str, phase_seconds: float = CALIBRATION_PHASE_SECONDS
    ) -> None:
        self.patient_id = patient_id
        self.phase_seconds = phase_seconds
        self.recordings: dict[str, PhaseRecording] = {
            phase: PhaseRecording(phase) for phase in CALIBRATION_PHASES
        }

    def add_frame(self, phase: str, frame: FrameFeatures) -> None:
        if phase not in self.recordings:
            raise CalibrationError(f"unknown calibration phase {phase!r}")
        self.recordings[phase].frames.append(frame)

    def add_frames(self, phase: str, frames: Iterable[FrameFeatures]) -> None:
        for frame in frames:
            self.add_frame(phase, frame)

    def progress(self, phase: str) -> float:
        return min(1.0, self.recordings[phase].seconds / self.phase_seconds)

    def missing_phases(self, *, minimum_seconds: float = MIN_PHASE_SECONDS) -> list[str]:
        return [phase for phase, rec in self.recordings.items() if rec.seconds < minimum_seconds]

    def build_profile(self, *, minimum_seconds: float = MIN_PHASE_SECONDS) -> PatientProfile:
        missing = self.missing_phases(minimum_seconds=minimum_seconds)
        if missing:
            raise CalibrationError("calibration phases too short: " + ", ".join(missing))
        blinking = self.recordings[CalibrationPhase.normal_blinking]
        rest = self.recordings[CalibrationPhase.rest_state]
        facial = self.recordings[CalibrationPhase.normal_facial_movement]
        intentional = self.recordings[CalibrationPhase.intentional_gestures]
        random_movement = self.recordings[CalibrationPhase.random_movement]

        # Blink pattern from the blinking + rest phases.
        blink_frames = blinking.frames + rest.frames
        ear = np.asarray([f["ear_mean"] for f in blink_frames])
        open_ear = float(np.percentile(ear, 85))
        blink_events = detect_blinks(
            [f.t_s for f in blinking.frames],
            [f["ear_mean"] for f in blinking.frames],
            open_ear=open_ear,
        )
        stats = blink_statistics(blink_events, blinking.seconds)
        blink = {
            "open_ear": open_ear,
            "rate_per_min": stats["rate_hz"] * 60.0,
            "mean_duration_ms": stats["mean_duration_ms"],
            "sd_duration_ms": stats["sd_duration_ms"],
            "mean_interval_s": stats["mean_interval_s"],
            "interval_cv": stats["interval_cv"],
            "closure_depth_mean": stats["mean_depth"],
            "closing_velocity_mean": stats["mean_velocity"],
            "count": stats["count"],
        }

        # Movement range across every phase (5th-95th percentile, widened slightly).
        all_matrix = np.concatenate([rec.matrix() for rec in self.recordings.values()])
        movement_range = {}
        for name in RANGE_CHANNELS:
            column = all_matrix[:, FRAME_INDEX[name]]
            lo, hi = np.percentile(column, [2, 98])
            pad = 0.05 * max(hi - lo, 1e-6)
            movement_range[name] = [float(lo - pad), float(hi + pad)]

        rest_matrix = rest.matrix()
        facial_matrix = facial.matrix()
        baseline = {
            "per_channel_mean": rest_matrix.mean(axis=0).tolist(),
            "per_channel_std": np.maximum(rest_matrix.std(axis=0), 1e-6).tolist(),
            "motion_energy_rest": float(rest_matrix[:, FRAME_INDEX["flow_mag_mean"]].mean()),
            "motion_energy_facial": float(facial_matrix[:, FRAME_INDEX["flow_mag_mean"]].mean()),
            "motion_energy_random": float(
                random_movement.matrix()[:, FRAME_INDEX["flow_mag_mean"]].mean()
            ),
            "channel_names": list(FRAME_FEATURES),
        }

        # Involuntary profile: how rhythmic / high-frequency the patient is at rest.
        rest_windows = _windows(rest, open_ear)
        random_windows = _windows(random_movement, open_ear)
        rest_hf = float(np.mean(rest_matrix[:, FRAME_INDEX["flow_hf_ratio"]]))
        involuntary = {
            "hf_ratio_rest": rest_hf,
            "hf_ratio_random": float(
                np.mean(random_movement.matrix()[:, FRAME_INDEX["flow_hf_ratio"]])
            ),
            "head_rhythmicity_rest": float(
                np.mean(rest_windows[:, _event_index("head_rhythmicity")])
            )
            if len(rest_windows)
            else 0.0,
            "face_jerk_rest": float(np.mean(rest_windows[:, _event_index("face_jerk_rms")]))
            if len(rest_windows)
            else 0.0,
            "face_jerk_random": float(np.mean(random_windows[:, _event_index("face_jerk_rms")]))
            if len(random_windows)
            else 0.0,
        }

        # Normaliser: mean/std over all phases, floored so quiet channels stay finite.
        mean = all_matrix.mean(axis=0)
        std = np.maximum(all_matrix.std(axis=0), 1e-3)
        normalizer = {"mean": mean.tolist(), "std": std.tolist()}

        prototypes: dict[str, dict[str, list[float]]] = {}
        for phase, rec in self.recordings.items():
            windows = _windows(rec, open_ear)
            if len(windows) == 0:
                continue
            prototypes[phase] = {
                "mean": windows.mean(axis=0).tolist(),
                "std": np.maximum(windows.std(axis=0), 1e-3).tolist(),
                "count": [float(len(windows))],
            }

        # Gesture thresholds: separability of intentional vs random/rest windows
        # decides how much the patient-specific layer is trusted.
        intentional_windows = _windows(intentional, open_ear)
        separability = _separability(
            intentional_windows,
            np.concatenate([random_windows, rest_windows])
            if len(random_windows) or len(rest_windows)
            else intentional_windows,
        )
        gesture_thresholds = {
            "intent_ignore_below": IGNORE_BELOW,
            "intent_execute_at": EXECUTE_AT,
            "prototype_weight": float(np.clip(0.2 + 0.6 * separability, 0.2, 0.8)),
            "separability": float(separability),
            "per_command": {
                c.value: EXECUTE_AT for c in CommandClass if c != CommandClass.non_command
            },
            "confirmation_window_s": 8.0,
        }

        from .schema import DEFAULT_COMMAND_SIGNALS

        return PatientProfile(
            patient_id=self.patient_id,
            created_at=datetime.now(UTC).isoformat(timespec="seconds"),
            phases={
                phase: {"seconds": rec.seconds, "frames": float(len(rec.frames))}
                for phase, rec in self.recordings.items()
            },
            blink=blink,
            movement_range=movement_range,
            baseline_facial_activity=baseline,
            involuntary_profile=involuntary,
            gesture_thresholds=gesture_thresholds,
            normalizer=normalizer,
            prototypes=prototypes,
            command_map=dict(DEFAULT_COMMAND_SIGNALS),
        )


def _event_index(name: str) -> int:
    from .schema import WINDOW_FEATURES

    return WINDOW_FEATURES.index(name)


def _windows(
    recording: PhaseRecording, open_ear: float, *, hop: int = WINDOW_FRAMES // 2
) -> FloatArray:
    frames = recording.frames
    if len(frames) < WINDOW_FRAMES:
        if len(frames) < 4:
            return np.zeros((0, WINDOW_FEATURE_COUNT))
        return window_features(frames, open_ear=open_ear)[None, :]
    rows = [
        window_features(frames[start : start + WINDOW_FRAMES], open_ear=open_ear)
        for start in range(0, len(frames) - WINDOW_FRAMES + 1, max(1, hop))
    ]
    return np.stack(rows)


def _separability(positive: FloatArray, negative: FloatArray) -> float:
    """Bounded 0..1 measure of how distinct two window sets are (mean z-distance)."""

    if len(positive) == 0 or len(negative) == 0:
        return 0.0
    pooled_std = np.maximum(np.concatenate([positive, negative]).std(axis=0), 1e-6)
    distance = float(np.mean(np.abs(positive.mean(axis=0) - negative.mean(axis=0)) / pooled_std))
    return float(1.0 - math.exp(-distance))


def frames_from_rows(timestamps: Sequence[float], rows: FloatArray) -> list[FrameFeatures]:
    return [
        FrameFeatures(float(t), np.asarray(row)) for t, row in zip(timestamps, rows, strict=False)
    ]


def run_synthetic_calibration(
    patient_id: str, *, seed: int = 1, seconds: float = CALIBRATION_PHASE_SECONDS
) -> PatientProfile:
    """Convenience for demos/tests: build a profile from simulated recordings."""

    from .synthetic import generate_calibration_phase

    rng = np.random.default_rng(seed)
    session = CalibrationSession(patient_id=patient_id, phase_seconds=seconds)
    for phase in CalibrationPhase:
        clip = generate_calibration_phase(rng, phase, seconds=seconds)
        session.add_frames(phase, frames_from_rows(clip.timestamps, clip.values))
    return session.build_profile()


__all__ = [
    "CalibrationError",
    "CalibrationSession",
    "PatientProfile",
    "PhaseRecording",
    "frames_from_rows",
    "run_synthetic_calibration",
    "FRAME_RATE_HZ",
]
