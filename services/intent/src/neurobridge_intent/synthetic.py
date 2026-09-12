"""Physiologically-motivated synthetic movement generator.

Real patient recordings are the ground truth; they arrive through the calibration
protocol and the ``record`` CLI. This module exists so the bootstrap models, the
Dart parity tests and CI can run without any patient data. Every generator produces
the 28-channel frame schema at the nominal rate. The signal models are deliberately
simple and documented:

* spontaneous blinks: Poisson arrivals ~15-20/min, 100-350 ms closures
* intentional blink patterns: 2 or 3 sharp closures 250-450 ms apart, or a
  >= 900 ms held closure
* held expressions: ramp (300 ms) -> hold (0.8-2 s) -> release (300 ms)
* tremor / twitch: 4-12 Hz low-amplitude oscillation on a random channel
* spasm: sudden large-amplitude jerk with irregular decay and no hold
* seizure-like: sustained 2.5-6 Hz rhythmic high-amplitude oscillation of head and
  face channels for several seconds
* random movement: smooth random walks on several channels with no hold phase
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from numpy.typing import NDArray

from .schema import (
    FRAME_FEATURE_COUNT,
    FRAME_INDEX,
    FRAME_RATE_HZ,
    AbnormalClass,
    CommandClass,
)

FloatArray = NDArray[np.float64]

BASE_EAR = 0.30
BASE_MOUTH = 0.08
BASE_BROW = 0.42
BASE_SMILE = 0.02


@dataclass(frozen=True, slots=True)
class SyntheticClip:
    values: FloatArray  # (T, C)
    timestamps: FloatArray  # (T,)
    command: str
    abnormal: str
    intentional: bool
    phase: str | None = None


def _base(rng: np.random.Generator, frames: int, *, noise: float = 1.0) -> FloatArray:
    m = np.zeros((frames, FRAME_FEATURE_COUNT), dtype=np.float64)
    m[:, FRAME_INDEX["ear_left"]] = BASE_EAR + rng.normal(0, 0.006 * noise, frames)
    m[:, FRAME_INDEX["ear_right"]] = BASE_EAR + rng.normal(0, 0.006 * noise, frames)
    m[:, FRAME_INDEX["mouth_open_ratio"]] = BASE_MOUTH + rng.normal(0, 0.004 * noise, frames)
    m[:, FRAME_INDEX["smile_ratio"]] = BASE_SMILE + np.abs(rng.normal(0, 0.004 * noise, frames))
    m[:, FRAME_INDEX["mouth_asymmetry"]] = np.abs(rng.normal(0, 0.003 * noise, frames))
    m[:, FRAME_INDEX["lip_motion"]] = np.abs(rng.normal(0, 0.002 * noise, frames))
    m[:, FRAME_INDEX["brow_raise"]] = BASE_BROW + rng.normal(0, 0.006 * noise, frames)
    # Slow physiological sway of the head (breathing / posture).
    t = np.arange(frames) / FRAME_RATE_HZ
    sway = 0.6 * np.sin(2 * np.pi * 0.25 * t + rng.uniform(0, 6.28))
    m[:, FRAME_INDEX["head_yaw"]] = sway + rng.normal(0, 0.25 * noise, frames)
    m[:, FRAME_INDEX["head_pitch"]] = 0.5 * sway + rng.normal(0, 0.25 * noise, frames)
    m[:, FRAME_INDEX["head_roll"]] = rng.normal(0, 0.2 * noise, frames)
    m[:, FRAME_INDEX["face_cx"]] = 0.5 + 0.002 * sway + rng.normal(0, 0.0008 * noise, frames)
    m[:, FRAME_INDEX["face_cy"]] = 0.45 + 0.001 * sway + rng.normal(0, 0.0008 * noise, frames)
    m[:, FRAME_INDEX["face_scale"]] = 0.18 + rng.normal(0, 0.001 * noise, frames)
    m[:, FRAME_INDEX["elbow_angle"]] = 150.0 + rng.normal(0, 1.0 * noise, frames)
    m[:, FRAME_INDEX["flow_mag_mean"]] = np.abs(rng.normal(0.02, 0.01 * noise, frames))
    m[:, FRAME_INDEX["flow_mag_std"]] = np.abs(rng.normal(0.01, 0.005 * noise, frames))
    m[:, FRAME_INDEX["flow_dir_consistency"]] = rng.uniform(0.1, 0.4, frames)
    return m


def _finalize(m: FloatArray) -> FloatArray:
    """Fill the derived channels (ear_mean, speeds, flow frequency) consistently."""

    dt = 1.0 / FRAME_RATE_HZ
    m[:, FRAME_INDEX["ear_mean"]] = (
        m[:, FRAME_INDEX["ear_left"]] + m[:, FRAME_INDEX["ear_right"]]
    ) / 2
    yaw, pitch, roll = (m[:, FRAME_INDEX[k]] for k in ("head_yaw", "head_pitch", "head_roll"))
    ang = np.sqrt(
        np.gradient(yaw, dt) ** 2 + np.gradient(pitch, dt) ** 2 + np.gradient(roll, dt) ** 2
    )
    m[:, FRAME_INDEX["head_angular_speed"]] = ang
    present = m[:, FRAME_INDEX["hand_present"]] > 0.5
    if present.any():
        wx, wy = m[:, FRAME_INDEX["wrist_x"]], m[:, FRAME_INDEX["wrist_y"]]
        vx, vy = np.gradient(wx, dt), np.gradient(wy, dt)
        speed = np.hypot(vx, vy) * present
        m[:, FRAME_INDEX["hand_speed"]] = speed
        m[:, FRAME_INDEX["hand_accel"]] = np.gradient(speed, dt) * present
        m[:, FRAME_INDEX["hand_direction"]] = np.arctan2(vy, vx) * present
    # Motion energy proxies follow the total movement in the clip.
    energy = (
        ang / 120.0
        + np.abs(np.gradient(m[:, FRAME_INDEX["mouth_open_ratio"]], dt))
        + np.abs(np.gradient(m[:, FRAME_INDEX["brow_raise"]], dt))
        + m[:, FRAME_INDEX["hand_speed"]]
    )
    m[:, FRAME_INDEX["flow_mag_mean"]] += energy * 0.5
    m[:, FRAME_INDEX["flow_mag_std"]] += energy * 0.2
    from .features.optical_flow import FlowSeriesAnalyzer

    series = FlowSeriesAnalyzer(rate_hz=FRAME_RATE_HZ, seconds=2.0)
    for i in range(m.shape[0]):
        dominant, hf = series.push(float(m[i, FRAME_INDEX["flow_mag_mean"]]))
        m[i, FRAME_INDEX["flow_dominant_hz"]] = dominant
        m[i, FRAME_INDEX["flow_hf_ratio"]] = hf
    m[:, FRAME_INDEX["ear_left"]] = np.clip(m[:, FRAME_INDEX["ear_left"]], 0, 0.6)
    m[:, FRAME_INDEX["ear_right"]] = np.clip(m[:, FRAME_INDEX["ear_right"]], 0, 0.6)
    m[:, FRAME_INDEX["ear_mean"]] = np.clip(m[:, FRAME_INDEX["ear_mean"]], 0, 0.6)
    m[:, FRAME_INDEX["mouth_open_ratio"]] = np.clip(m[:, FRAME_INDEX["mouth_open_ratio"]], 0, 1)
    m[:, FRAME_INDEX["smile_ratio"]] = np.clip(m[:, FRAME_INDEX["smile_ratio"]], 0, 1)
    return m


def _closure(m: FloatArray, start: int, duration_frames: int, depth: float = 0.85) -> None:
    end = min(m.shape[0], start + max(1, duration_frames))
    n = end - start
    if n <= 0:
        return
    profile = np.sin(np.linspace(0, np.pi, n)) * depth
    for key in ("ear_left", "ear_right"):
        m[start:end, FRAME_INDEX[key]] *= 1.0 - profile


def _ramp_hold(
    m: FloatArray, key: str, start: int, amplitude: float, hold_frames: int, ramp_frames: int = 6
) -> int:
    """Ramp a channel up, hold, ramp down. Returns the frame after release."""

    n = m.shape[0]
    up = np.linspace(0, 1, ramp_frames)
    down = np.linspace(1, 0, ramp_frames)
    profile = np.concatenate([up, np.ones(hold_frames), down]) * amplitude
    end = min(n, start + len(profile))
    m[start:end, FRAME_INDEX[key]] += profile[: end - start]
    return end


def spontaneous_blinks(
    rng: np.random.Generator, m: FloatArray, *, rate_per_min: float = 17.0
) -> None:
    frames = m.shape[0]
    t = 0.0
    while True:
        t += rng.exponential(60.0 / rate_per_min)
        start = int(t * FRAME_RATE_HZ)
        if start >= frames - 2:
            break
        duration = int(rng.uniform(0.10, 0.35) * FRAME_RATE_HZ)
        _closure(m, start, max(2, duration), depth=rng.uniform(0.7, 0.95))


def _hand_raise(rng: np.random.Generator, m: FloatArray, start: int, hold_frames: int) -> None:
    n = m.shape[0]
    ramp = 8
    profile = np.concatenate(
        [np.linspace(0, 1, ramp), np.ones(hold_frames), np.linspace(1, 0, ramp)]
    )
    end = min(n, start + len(profile))
    seg = profile[: end - start]
    m[start:end, FRAME_INDEX["hand_present"]] = 1.0
    m[start:end, FRAME_INDEX["wrist_x"]] = 0.62 + 0.03 * seg + rng.normal(0, 0.002, end - start)
    m[start:end, FRAME_INDEX["wrist_y"]] = 0.85 - 0.35 * seg + rng.normal(0, 0.002, end - start)
    m[start:end, FRAME_INDEX["elbow_angle"]] = 150 - 70 * seg
    m[start:end, FRAME_INDEX["shoulder_motion"]] = 0.004 * np.abs(np.gradient(seg))


def generate_command(
    rng: np.random.Generator, command: str, *, seconds: float = 3.0, noise: float = 1.0
) -> SyntheticClip:
    frames = int(seconds * FRAME_RATE_HZ)
    m = _base(rng, frames, noise=noise)
    start = int(rng.uniform(0.2, 0.6) * FRAME_RATE_HZ)
    abnormal = AbnormalClass.normal_voluntary
    intentional = True
    if command == CommandClass.non_command:
        spontaneous_blinks(rng, m)
        intentional = False
    elif command == CommandClass.triple_blink:
        gap = int(rng.uniform(0.28, 0.45) * FRAME_RATE_HZ)
        for k in range(3):
            _closure(m, start + k * gap, int(rng.uniform(0.12, 0.22) * FRAME_RATE_HZ) + 1)
    elif command == CommandClass.double_blink:
        gap = int(rng.uniform(0.28, 0.45) * FRAME_RATE_HZ)
        for k in range(2):
            _closure(m, start + k * gap, int(rng.uniform(0.12, 0.22) * FRAME_RATE_HZ) + 1)
    elif command == CommandClass.long_blink:
        _closure(m, start, int(rng.uniform(0.9, 1.6) * FRAME_RATE_HZ), depth=0.9)
    elif command == CommandClass.mouth_open_hold:
        _ramp_hold(
            m,
            "mouth_open_ratio",
            start,
            rng.uniform(0.18, 0.35),
            int(rng.uniform(0.8, 1.8) * FRAME_RATE_HZ),
        )
    elif command == CommandClass.smile_hold:
        end = _ramp_hold(
            m,
            "smile_ratio",
            start,
            rng.uniform(0.10, 0.20),
            int(rng.uniform(0.8, 1.8) * FRAME_RATE_HZ),
        )
        m[start:end, FRAME_INDEX["ear_left"]] -= 0.03
        m[start:end, FRAME_INDEX["ear_right"]] -= 0.03
    elif command == CommandClass.brow_raise_hold:
        _ramp_hold(
            m,
            "brow_raise",
            start,
            rng.uniform(0.06, 0.12),
            int(rng.uniform(0.8, 1.8) * FRAME_RATE_HZ),
        )
    elif command == CommandClass.head_left_hold:
        _ramp_hold(
            m,
            "head_yaw",
            start,
            -rng.uniform(14, 26),
            int(rng.uniform(0.8, 1.8) * FRAME_RATE_HZ),
            ramp_frames=8,
        )
    elif command == CommandClass.head_right_hold:
        _ramp_hold(
            m,
            "head_yaw",
            start,
            rng.uniform(14, 26),
            int(rng.uniform(0.8, 1.8) * FRAME_RATE_HZ),
            ramp_frames=8,
        )
    elif command == CommandClass.hand_raise_hold:
        _hand_raise(rng, m, start, int(rng.uniform(0.8, 1.6) * FRAME_RATE_HZ))
    else:
        raise ValueError(f"unknown command {command!r}")
    if command != CommandClass.non_command and rng.uniform() < 0.5:
        # Commands happen on top of ordinary blinking too.
        spontaneous_blinks(rng, m, rate_per_min=10)
    m = _finalize(m)
    return SyntheticClip(m, np.arange(frames) / FRAME_RATE_HZ, command, abnormal, intentional)


def generate_abnormal(
    rng: np.random.Generator, kind: str, *, seconds: float = 3.0, noise: float = 1.0
) -> SyntheticClip:
    frames = int(seconds * FRAME_RATE_HZ)
    m = _base(rng, frames, noise=noise)
    t = np.arange(frames) / FRAME_RATE_HZ
    if kind == AbnormalClass.normal_voluntary:
        return generate_command(
            rng,
            rng.choice([c for c in CommandClass if c != CommandClass.non_command]),
            seconds=seconds,
            noise=noise,
        )
    if kind == AbnormalClass.involuntary:
        # Twitch/tremor: high-frequency low-amplitude bursts on lip, brow or head.
        freq = rng.uniform(4.0, 12.0)
        burst_start = int(rng.uniform(0.2, 1.0) * FRAME_RATE_HZ)
        burst_len = int(rng.uniform(0.6, 2.0) * FRAME_RATE_HZ)
        env = np.zeros(frames)
        env[burst_start : burst_start + burst_len] = 1.0
        osc = np.sin(2 * np.pi * freq * t) * env
        target = rng.choice(["lip", "brow", "head", "eye"])
        if target == "lip":
            m[:, FRAME_INDEX["lip_motion"]] += np.abs(osc) * 0.03
            m[:, FRAME_INDEX["mouth_asymmetry"]] += np.abs(osc) * 0.02
            m[:, FRAME_INDEX["mouth_open_ratio"]] += osc * 0.015
        elif target == "brow":
            m[:, FRAME_INDEX["brow_raise"]] += osc * 0.02
        elif target == "eye":
            m[:, FRAME_INDEX["ear_left"]] += osc * 0.03
        else:
            m[:, FRAME_INDEX["head_yaw"]] += osc * 1.5
            m[:, FRAME_INDEX["head_roll"]] += osc * 1.0
        m[:, FRAME_INDEX["flow_mag_mean"]] += np.abs(osc) * 0.08
        m[:, FRAME_INDEX["flow_mag_std"]] += np.abs(osc) * 0.05
        m[:, FRAME_INDEX["flow_dir_consistency"]] *= 0.5
        spontaneous_blinks(rng, m)
        m = _finalize(m)
        return SyntheticClip(m, t, CommandClass.non_command, kind, False)
    if kind == AbnormalClass.possible_spasm:
        # Sudden stretch/jerk: fast large excursion, irregular decay, no hold.
        onset = int(rng.uniform(0.3, 1.2) * FRAME_RATE_HZ)
        length = int(rng.uniform(0.5, 1.5) * FRAME_RATE_HZ)
        idx = np.arange(length)
        jerk = np.exp(-idx / (length / 3)) * (1 + 0.6 * np.sin(idx * rng.uniform(0.8, 2.5)))
        jerk = jerk * rng.uniform(0.7, 1.3)
        end = min(frames, onset + length)
        seg = jerk[: end - onset]
        m[onset:end, FRAME_INDEX["head_yaw"]] += seg * rng.uniform(15, 35) * rng.choice([-1, 1])
        m[onset:end, FRAME_INDEX["head_pitch"]] += seg * rng.uniform(8, 20) * rng.choice([-1, 1])
        m[onset:end, FRAME_INDEX["mouth_open_ratio"]] += seg * rng.uniform(0.1, 0.3)
        m[onset:end, FRAME_INDEX["face_cx"]] += seg * 0.03 * rng.choice([-1, 1])
        m[onset:end, FRAME_INDEX["face_cy"]] += seg * 0.02
        if rng.uniform() < 0.5:
            m[onset:end, FRAME_INDEX["hand_present"]] = 1.0
            m[onset:end, FRAME_INDEX["wrist_x"]] = 0.6 + seg * 0.15
            m[onset:end, FRAME_INDEX["wrist_y"]] = 0.8 - seg * 0.25
            m[onset:end, FRAME_INDEX["elbow_angle"]] = 150 - seg * 90
        m[onset:end, FRAME_INDEX["flow_mag_mean"]] += seg * 0.3
        m[onset:end, FRAME_INDEX["flow_mag_std"]] += seg * 0.2
        m = _finalize(m)
        return SyntheticClip(m, t, CommandClass.non_command, kind, False)
    if kind == AbnormalClass.possible_seizure_like:
        freq = rng.uniform(2.5, 6.0)
        onset = int(rng.uniform(0.0, 0.5) * FRAME_RATE_HZ)
        env = np.zeros(frames)
        env[onset:] = np.minimum(1.0, np.arange(frames - onset) / (0.4 * FRAME_RATE_HZ))
        osc = np.sin(2 * np.pi * freq * t + rng.uniform(0, 6.28)) * env
        osc2 = np.sin(2 * np.pi * freq * t + rng.uniform(0, 6.28)) * env
        m[:, FRAME_INDEX["head_yaw"]] += osc * rng.uniform(6, 15)
        m[:, FRAME_INDEX["head_pitch"]] += osc2 * rng.uniform(5, 12)
        m[:, FRAME_INDEX["head_roll"]] += osc * rng.uniform(3, 8)
        m[:, FRAME_INDEX["face_cx"]] += osc * 0.02
        m[:, FRAME_INDEX["face_cy"]] += osc2 * 0.015
        m[:, FRAME_INDEX["mouth_open_ratio"]] += np.abs(osc) * 0.12
        m[:, FRAME_INDEX["ear_left"]] -= np.abs(osc) * 0.08
        m[:, FRAME_INDEX["ear_right"]] -= np.abs(osc) * 0.08
        m[:, FRAME_INDEX["lip_motion"]] += np.abs(osc) * 0.02
        m[:, FRAME_INDEX["hand_present"]] = 1.0
        m[:, FRAME_INDEX["wrist_x"]] = 0.6 + osc * 0.06
        m[:, FRAME_INDEX["wrist_y"]] = 0.8 + osc2 * 0.06
        m[:, FRAME_INDEX["elbow_angle"]] = 120 + osc * 30
        m[:, FRAME_INDEX["flow_mag_mean"]] += np.abs(osc) * 0.35
        m[:, FRAME_INDEX["flow_mag_std"]] += np.abs(osc) * 0.15
        m[:, FRAME_INDEX["flow_dir_consistency"]] = rng.uniform(0.05, 0.3, frames)
        m = _finalize(m)
        return SyntheticClip(m, t, CommandClass.non_command, kind, False)
    raise ValueError(f"unknown abnormal kind {kind!r}")


def generate_random_movement(
    rng: np.random.Generator, *, seconds: float = 3.0, noise: float = 1.0
) -> SyntheticClip:
    """Accidental / random movement: smooth wandering without ramp-hold-release."""

    frames = int(seconds * FRAME_RATE_HZ)
    m = _base(rng, frames, noise=noise)
    t = np.arange(frames) / FRAME_RATE_HZ
    for key, amp in (
        ("head_yaw", 10),
        ("head_pitch", 6),
        ("mouth_open_ratio", 0.08),
        ("brow_raise", 0.04),
        ("smile_ratio", 0.05),
    ):
        if rng.uniform() < 0.7:
            f1, f2 = rng.uniform(0.3, 1.2, 2)
            walk = np.sin(2 * np.pi * f1 * t + rng.uniform(0, 6.28)) + 0.5 * np.sin(
                2 * np.pi * f2 * t + rng.uniform(0, 6.28)
            )
            m[:, FRAME_INDEX[key]] += walk * amp * rng.uniform(0.4, 1.0)
    if rng.uniform() < 0.4:
        m[:, FRAME_INDEX["hand_present"]] = 1.0
        m[:, FRAME_INDEX["wrist_x"]] = 0.6 + 0.05 * np.sin(2 * np.pi * 0.5 * t)
        m[:, FRAME_INDEX["wrist_y"]] = 0.8 + 0.05 * np.cos(2 * np.pi * 0.4 * t)
    spontaneous_blinks(rng, m)
    m = _finalize(m)
    return SyntheticClip(m, t, CommandClass.non_command, AbnormalClass.normal_voluntary, False)


def generate_rest(
    rng: np.random.Generator, *, seconds: float = 3.0, noise: float = 1.0
) -> SyntheticClip:
    frames = int(seconds * FRAME_RATE_HZ)
    m = _base(rng, frames, noise=noise * 0.6)
    spontaneous_blinks(rng, m, rate_per_min=12)
    m = _finalize(m)
    return SyntheticClip(
        m,
        np.arange(frames) / FRAME_RATE_HZ,
        CommandClass.non_command,
        AbnormalClass.normal_voluntary,
        False,
    )


def generate_dataset(
    *, seed: int = 7, per_class: int = 40, seconds: float = 3.0, noise: float = 1.0
) -> list[SyntheticClip]:
    """Balanced bootstrap dataset covering every command and abnormal class."""

    rng = np.random.default_rng(seed)
    clips: list[SyntheticClip] = []
    for command in CommandClass:
        for _ in range(per_class):
            clips.append(
                generate_command(rng, command, seconds=seconds, noise=noise * rng.uniform(0.6, 1.4))
            )
    for kind in (
        AbnormalClass.involuntary,
        AbnormalClass.possible_spasm,
        AbnormalClass.possible_seizure_like,
    ):
        for _ in range(per_class):
            clips.append(
                generate_abnormal(rng, kind, seconds=seconds, noise=noise * rng.uniform(0.6, 1.4))
            )
    for _ in range(per_class):
        clips.append(
            generate_random_movement(rng, seconds=seconds, noise=noise * rng.uniform(0.6, 1.4))
        )
        clips.append(generate_rest(rng, seconds=seconds, noise=noise * rng.uniform(0.6, 1.4)))
    return clips


def generate_calibration_phase(
    rng: np.random.Generator, phase: str, *, seconds: float = 30.0
) -> SyntheticClip:
    """Simulate one 30-second calibration recording for tests and demos."""

    from .schema import CalibrationPhase

    if phase == CalibrationPhase.normal_blinking:
        clip = generate_rest(rng, seconds=seconds)
        m = clip.values.copy()
        spontaneous_blinks(rng, m, rate_per_min=18)
        return SyntheticClip(
            _finalize(m),
            clip.timestamps,
            CommandClass.non_command,
            AbnormalClass.normal_voluntary,
            False,
            phase,
        )
    if phase == CalibrationPhase.normal_facial_movement:
        clip = generate_random_movement(rng, seconds=seconds, noise=0.8)
        return SyntheticClip(
            clip.values, clip.timestamps, clip.command, clip.abnormal, False, phase
        )
    if phase == CalibrationPhase.intentional_gestures:
        pieces = []
        commands = [c for c in CommandClass if c != CommandClass.non_command]
        while sum(p.shape[0] for p in pieces) < int(seconds * FRAME_RATE_HZ):
            pieces.append(generate_command(rng, rng.choice(commands), seconds=3.0).values)
        m = np.concatenate(pieces)[: int(seconds * FRAME_RATE_HZ)]
        return SyntheticClip(
            m,
            np.arange(m.shape[0]) / FRAME_RATE_HZ,
            CommandClass.non_command,
            AbnormalClass.normal_voluntary,
            True,
            phase,
        )
    if phase == CalibrationPhase.random_movement:
        clip = generate_random_movement(rng, seconds=seconds, noise=1.2)
        return SyntheticClip(
            clip.values, clip.timestamps, clip.command, clip.abnormal, False, phase
        )
    if phase == CalibrationPhase.rest_state:
        clip = generate_rest(rng, seconds=seconds, noise=0.5)
        return SyntheticClip(
            clip.values, clip.timestamps, clip.command, clip.abnormal, False, phase
        )
    raise ValueError(f"unknown calibration phase {phase!r}")
