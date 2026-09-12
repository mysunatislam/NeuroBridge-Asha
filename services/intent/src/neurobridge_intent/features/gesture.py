"""Upper-limb gesture features from MediaPipe Hands and Pose landmarks.

Channels: wrist position, elbow angle, shoulder motion, hand speed, acceleration and
movement direction. Coordinates are normalised image coordinates (0..1).
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
from numpy.typing import ArrayLike, NDArray

FloatArray = NDArray[np.float64]

# MediaPipe Pose indices.
POSE_LEFT_SHOULDER, POSE_RIGHT_SHOULDER = 11, 12
POSE_LEFT_ELBOW, POSE_RIGHT_ELBOW = 13, 14
POSE_LEFT_WRIST, POSE_RIGHT_WRIST = 15, 16
HAND_WRIST = 0


def joint_angle(a: ArrayLike, b: ArrayLike, c: ArrayLike) -> float:
    """Angle at ``b`` in degrees for the chain a-b-c."""

    pa, pb, pc = (np.asarray(p, dtype=np.float64)[:2] for p in (a, b, c))
    v1, v2 = pa - pb, pc - pb
    n1, n2 = np.linalg.norm(v1), np.linalg.norm(v2)
    if n1 <= 1e-9 or n2 <= 1e-9:
        return 180.0
    cosine = float(np.clip(np.dot(v1, v2) / (n1 * n2), -1.0, 1.0))
    return math.degrees(math.acos(cosine))


@dataclass(frozen=True, slots=True)
class GestureMetrics:
    hand_present: float
    wrist_x: float
    wrist_y: float
    hand_speed: float
    hand_accel: float
    hand_direction: float  # radians, 0 when stationary
    elbow_angle: float
    shoulder_motion: float


class GestureFeatureExtractor:
    """Combines hand and pose landmarks; either may be missing on a frame."""

    def __init__(self) -> None:
        self._prev: tuple[float, float, float] | None = None  # t, x, y
        self._prev_speed: tuple[float, float] | None = None  # t, speed
        self._prev_shoulders: FloatArray | None = None

    def reset(self) -> None:
        self._prev = None
        self._prev_speed = None
        self._prev_shoulders = None

    def extract(
        self,
        t_s: float,
        *,
        hand_landmarks: ArrayLike | None = None,
        pose_landmarks: ArrayLike | None = None,
    ) -> GestureMetrics:
        wrist: FloatArray | None = None
        elbow_angle = 180.0
        shoulder_motion = 0.0

        if pose_landmarks is not None:
            pose = np.asarray(pose_landmarks, dtype=np.float64)
            if pose.shape[0] >= 17:
                # Pick the arm whose wrist is higher in the frame (smaller y).
                left_wrist, right_wrist = pose[POSE_LEFT_WRIST], pose[POSE_RIGHT_WRIST]
                if left_wrist[1] <= right_wrist[1]:
                    wrist = left_wrist[:2]
                    elbow_angle = joint_angle(
                        pose[POSE_LEFT_SHOULDER], pose[POSE_LEFT_ELBOW], left_wrist
                    )
                else:
                    wrist = right_wrist[:2]
                    elbow_angle = joint_angle(
                        pose[POSE_RIGHT_SHOULDER], pose[POSE_RIGHT_ELBOW], right_wrist
                    )
                shoulders = pose[[POSE_LEFT_SHOULDER, POSE_RIGHT_SHOULDER], :2]
                if self._prev_shoulders is not None:
                    shoulder_motion = float(
                        np.mean(np.linalg.norm(shoulders - self._prev_shoulders, axis=1))
                    )
                self._prev_shoulders = shoulders

        if hand_landmarks is not None:
            hand = np.asarray(hand_landmarks, dtype=np.float64)
            if hand.shape[0] >= 21:
                wrist = hand[HAND_WRIST][:2]

        if wrist is None:
            self._prev = None
            self._prev_speed = None
            return GestureMetrics(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, elbow_angle, shoulder_motion)

        x, y = float(wrist[0]), float(wrist[1])
        speed = 0.0
        accel = 0.0
        direction = 0.0
        if self._prev is not None:
            pt, px, py = self._prev
            dt = t_s - pt
            if dt > 0:
                dx, dy = x - px, y - py
                speed = math.hypot(dx, dy) / dt
                direction = math.atan2(dy, dx) if speed > 1e-6 else 0.0
                if self._prev_speed is not None and t_s - self._prev_speed[0] > 0:
                    accel = (speed - self._prev_speed[1]) / (t_s - self._prev_speed[0])
        self._prev = (t_s, x, y)
        self._prev_speed = (t_s, speed)
        return GestureMetrics(1.0, x, y, speed, accel, direction, elbow_angle, shoulder_motion)
