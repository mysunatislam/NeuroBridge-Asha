"""Facial feature extraction from MediaPipe Face Mesh / Face Landmarker landmarks.

Input is an ``(N, 3)`` array of normalised landmarks (468 or 478 points). All
outputs are dimensionless ratios relative to the inter-ocular distance so they are
robust to distance from the camera. Head pose is estimated from landmark geometry
without solvePnP so the same maths can run in Dart.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
from numpy.typing import ArrayLike, NDArray

FloatArray = NDArray[np.float64]

# MediaPipe 468-point mesh indices.
LEFT_EYE = (33, 160, 158, 133, 153, 144)  # p1..p6 for EAR
RIGHT_EYE = (362, 385, 387, 263, 373, 380)
LEFT_EYE_OUTER, RIGHT_EYE_OUTER = 33, 263
MOUTH_LEFT, MOUTH_RIGHT = 61, 291
UPPER_LIP_TOP, LOWER_LIP_BOTTOM = 13, 14
UPPER_LIP_OUTER, LOWER_LIP_OUTER = 0, 17
NOSE_TIP, CHIN, FOREHEAD = 1, 152, 10
LEFT_BROW, RIGHT_BROW = 105, 334
LEFT_EYE_TOP, RIGHT_EYE_TOP = 159, 386
LIP_RING = (
    61,
    146,
    91,
    181,
    84,
    17,
    314,
    405,
    321,
    375,
    291,
    409,
    270,
    269,
    267,
    0,
    37,
    39,
    40,
    185,
)


def _dist(a: FloatArray, b: FloatArray) -> float:
    return float(np.linalg.norm(a - b))


def eye_aspect_ratio(points: ArrayLike) -> float:
    """Soukupová & Čech EAR for six eye points ordered p1..p6."""

    p = np.asarray(points, dtype=np.float64)
    if p.shape[0] != 6:
        raise ValueError("EAR needs exactly six points")
    horizontal = _dist(p[0], p[3])
    if horizontal <= 1e-9:
        return 0.0
    vertical = _dist(p[1], p[5]) + _dist(p[2], p[4])
    return vertical / (2.0 * horizontal)


def mouth_metrics(landmarks: FloatArray, scale: float) -> tuple[float, float, float]:
    """Return (mouth_open_ratio, smile_ratio, asymmetry)."""

    opening = _dist(landmarks[UPPER_LIP_TOP], landmarks[LOWER_LIP_BOTTOM]) / scale
    width = _dist(landmarks[MOUTH_LEFT], landmarks[MOUTH_RIGHT]) / scale
    # Smile: corners rise relative to the lip centre and the mouth widens.
    centre_y = (landmarks[UPPER_LIP_OUTER][1] + landmarks[LOWER_LIP_OUTER][1]) / 2.0
    left_rise = (centre_y - landmarks[MOUTH_LEFT][1]) / scale
    right_rise = (centre_y - landmarks[MOUTH_RIGHT][1]) / scale
    smile = max(0.0, (left_rise + right_rise) / 2.0 + (width - 0.95) * 0.5)
    asymmetry = abs(left_rise - right_rise)
    return opening, smile, asymmetry


@dataclass(frozen=True, slots=True)
class FaceMetrics:
    ear_left: float
    ear_right: float
    mouth_open_ratio: float
    smile_ratio: float
    mouth_asymmetry: float
    lip_motion: float
    brow_raise: float
    head_yaw: float
    head_pitch: float
    head_roll: float
    head_angular_speed: float
    face_cx: float
    face_cy: float
    face_scale: float

    @property
    def ear_mean(self) -> float:
        return (self.ear_left + self.ear_right) / 2.0


class FaceFeatureExtractor:
    """Stateful per-frame face metric extractor (keeps only the previous frame)."""

    def __init__(self) -> None:
        self._previous_lips: FloatArray | None = None
        self._previous_pose: tuple[float, float, float, float] | None = None

    def reset(self) -> None:
        self._previous_lips = None
        self._previous_pose = None

    def extract(self, landmarks: ArrayLike, t_s: float) -> FaceMetrics:
        lm = np.asarray(landmarks, dtype=np.float64)
        if lm.ndim != 2 or lm.shape[0] < 468 or lm.shape[1] < 2:
            raise ValueError("landmarks must be an (>=468, >=2) array")
        if lm.shape[1] == 2:
            lm = np.concatenate([lm, np.zeros((lm.shape[0], 1))], axis=1)
        scale = _dist(lm[LEFT_EYE_OUTER], lm[RIGHT_EYE_OUTER])
        if scale <= 1e-6:
            scale = 1e-6

        ear_left = eye_aspect_ratio(lm[list(LEFT_EYE)])
        ear_right = eye_aspect_ratio(lm[list(RIGHT_EYE)])
        opening, smile, asymmetry = mouth_metrics(lm, scale)

        lips = (lm[list(LIP_RING)] - lm[NOSE_TIP]) / scale
        if self._previous_lips is None:
            lip_motion = 0.0
        else:
            lip_motion = float(np.mean(np.linalg.norm(lips - self._previous_lips, axis=1)))
        self._previous_lips = lips

        brow = (
            _dist(lm[LEFT_BROW], lm[LEFT_EYE_TOP]) + _dist(lm[RIGHT_BROW], lm[RIGHT_EYE_TOP])
        ) / (2.0 * scale)

        yaw, pitch, roll = estimate_head_pose(lm)
        if self._previous_pose is None:
            angular_speed = 0.0
        else:
            pt, py, pp, pr = self._previous_pose
            dt = t_s - pt
            angular_speed = (
                math.sqrt((yaw - py) ** 2 + (pitch - pp) ** 2 + (roll - pr) ** 2) / dt
                if dt > 0
                else 0.0
            )
        self._previous_pose = (t_s, yaw, pitch, roll)

        cx, cy = float(np.mean(lm[:, 0])), float(np.mean(lm[:, 1]))
        return FaceMetrics(
            ear_left=ear_left,
            ear_right=ear_right,
            mouth_open_ratio=opening,
            smile_ratio=smile,
            mouth_asymmetry=asymmetry,
            lip_motion=lip_motion,
            brow_raise=brow,
            head_yaw=yaw,
            head_pitch=pitch,
            head_roll=roll,
            head_angular_speed=angular_speed,
            face_cx=cx,
            face_cy=cy,
            face_scale=scale,
        )


def estimate_head_pose(lm: FloatArray) -> tuple[float, float, float]:
    """Approximate yaw/pitch/roll in degrees from landmark geometry.

    Yaw: nose tip offset between the eye corners. Pitch: nose tip position between
    forehead and chin. Roll: eye-line angle. Coarse but monotonic, and identical in
    the Dart port.
    """

    left, right = lm[LEFT_EYE_OUTER], lm[RIGHT_EYE_OUTER]
    nose, chin, forehead = lm[NOSE_TIP], lm[CHIN], lm[FOREHEAD]
    eye_width = _dist(left, right) or 1e-6
    mid_x = (left[0] + right[0]) / 2.0
    yaw = math.degrees(math.atan2(nose[0] - mid_x, eye_width * 0.55))
    face_height = abs(chin[1] - forehead[1]) or 1e-6
    nose_ratio = (nose[1] - forehead[1]) / face_height  # ~0.55 when level
    pitch = math.degrees(math.atan2((nose_ratio - 0.55) * 2.0, 1.0))
    roll = math.degrees(math.atan2(right[1] - left[1], right[0] - left[0]))
    return yaw, pitch, roll
