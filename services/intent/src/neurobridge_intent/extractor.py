"""MediaPipe Tasks feature extractor (optional ``vision`` extra).

Runs Face Landmarker, Hand Landmarker and Pose Landmarker on each camera frame and
emits one :class:`FrameFeatures`. Frames and landmarks are method-local and are
never stored or transmitted. Model ``.task`` files are downloaded once by
``neurobridge-intent models fetch`` into ``~/.neurobridge/models`` (or supplied
explicitly) so the runtime itself is fully offline.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

from .features.face import FaceFeatureExtractor
from .features.gesture import GestureFeatureExtractor
from .features.optical_flow import LandmarkFlowProxy, OpticalFlowAnalyzer
from .features.window import FrameFeatures
from .schema import FRAME_FEATURE_COUNT, FRAME_INDEX, FRAME_RATE_HZ

MODEL_URLS = {
    "face_landmarker.task": "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task",
    "hand_landmarker.task": "https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task",
    "pose_landmarker_lite.task": "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/1/pose_landmarker_lite.task",
}


def default_model_dir() -> Path:
    return Path.home() / ".neurobridge" / "models"


def fetch_models(directory: Path | None = None) -> dict[str, Path]:
    """One-time download of the MediaPipe task files (needs internet once)."""

    import urllib.request

    directory = directory or default_model_dir()
    directory.mkdir(parents=True, exist_ok=True)
    paths: dict[str, Path] = {}
    for name, url in MODEL_URLS.items():
        target = directory / name
        if not target.exists():
            urllib.request.urlretrieve(url, target)  # noqa: S310 - pinned Google URLs
        paths[name] = target
    return paths


@dataclass(slots=True)
class ExtractorConfig:
    model_dir: Path | None = None
    use_hands: bool = True
    use_pose: bool = True
    use_optical_flow: bool = True
    flow_roi_size: int = 96


class MediaPipeFeatureExtractor:
    """Stateful per-frame extractor. Call :meth:`process` with BGR frames."""

    def __init__(self, config: ExtractorConfig | None = None) -> None:
        self.config = config or ExtractorConfig()
        self._mp: Any | None = None
        self._face: Any | None = None
        self._hands: Any | None = None
        self._pose: Any | None = None
        self._face_features = FaceFeatureExtractor()
        self._gesture_features = GestureFeatureExtractor()
        self._flow = (
            OpticalFlowAnalyzer(rate_hz=FRAME_RATE_HZ, roi_size=self.config.flow_roi_size)
            if self.config.use_optical_flow
            else None
        )
        self._flow_proxy = LandmarkFlowProxy(rate_hz=FRAME_RATE_HZ)
        self._last_timestamp_ms = -1
        self._started = False

    def start(self) -> None:
        try:
            import mediapipe as mp
        except ModuleNotFoundError as exc:  # pragma: no cover - optional
            raise RuntimeError(
                "install the 'vision' extra (mediapipe) to run the camera extractor"
            ) from exc
        model_dir = self.config.model_dir or default_model_dir()
        paths = {name: model_dir / name for name in MODEL_URLS}
        missing = [name for name, path in paths.items() if not path.exists()]
        if missing:
            raise RuntimeError(
                f"missing MediaPipe models {missing}; run 'neurobridge-intent models fetch'"
            )
        vision = mp.tasks.vision
        base = mp.tasks.BaseOptions
        self._face = vision.FaceLandmarker.create_from_options(
            vision.FaceLandmarkerOptions(
                base_options=base(model_asset_path=str(paths["face_landmarker.task"])),
                running_mode=vision.RunningMode.VIDEO,
                num_faces=1,
            )
        )
        if self.config.use_hands:
            self._hands = vision.HandLandmarker.create_from_options(
                vision.HandLandmarkerOptions(
                    base_options=base(model_asset_path=str(paths["hand_landmarker.task"])),
                    running_mode=vision.RunningMode.VIDEO,
                    num_hands=1,
                )
            )
        if self.config.use_pose:
            self._pose = vision.PoseLandmarker.create_from_options(
                vision.PoseLandmarkerOptions(
                    base_options=base(model_asset_path=str(paths["pose_landmarker_lite.task"])),
                    running_mode=vision.RunningMode.VIDEO,
                )
            )
        self._mp = mp
        self._started = True

    def close(self) -> None:
        for task in (self._face, self._hands, self._pose):
            if task is not None:
                task.close()
        self._face = self._hands = self._pose = None
        self._started = False

    def process(self, frame_bgr: np.ndarray, t_s: float | None = None) -> FrameFeatures | None:
        """Return frame features, or None when no face is visible."""

        if not self._started or self._mp is None or self._face is None:
            raise RuntimeError("extractor is not started")
        mp = self._mp
        t_s = time.monotonic() if t_s is None else t_s
        rgb = np.ascontiguousarray(frame_bgr[:, :, ::-1])
        image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        timestamp_ms = max(self._last_timestamp_ms + 1, int(t_s * 1000))
        self._last_timestamp_ms = timestamp_ms

        face_result = self._face.detect_for_video(image, timestamp_ms)
        faces = getattr(face_result, "face_landmarks", None) or []
        if not faces:
            self._face_features.reset()
            self._flow_proxy.reset()
            if self._flow is not None:
                self._flow.reset()
            return None
        landmarks = np.asarray(
            [(p.x, p.y, getattr(p, "z", 0.0)) for p in faces[0]], dtype=np.float64
        )
        face = self._face_features.extract(landmarks, t_s)

        hand_landmarks = None
        if self._hands is not None:
            hand_result = self._hands.detect_for_video(image, timestamp_ms)
            hands = getattr(hand_result, "hand_landmarks", None) or []
            if hands:
                hand_landmarks = np.asarray(
                    [(p.x, p.y, getattr(p, "z", 0.0)) for p in hands[0]], dtype=np.float64
                )
        pose_landmarks = None
        if self._pose is not None:
            pose_result = self._pose.detect_for_video(image, timestamp_ms)
            poses = getattr(pose_result, "pose_landmarks", None) or []
            if poses:
                pose_landmarks = np.asarray(
                    [(p.x, p.y, getattr(p, "z", 0.0)) for p in poses[0]], dtype=np.float64
                )
        gesture = self._gesture_features.extract(
            t_s, hand_landmarks=hand_landmarks, pose_landmarks=pose_landmarks
        )

        height, width = frame_bgr.shape[:2]
        if self._flow is not None:
            xs, ys = landmarks[:, 0] * width, landmarks[:, 1] * height
            x0, y0 = int(xs.min()), int(ys.min())
            w, h = int(xs.max() - x0), int(ys.max() - y0)
            flow = self._flow.update(frame_bgr, (x0, y0, max(w, 8), max(h, 8)))
        else:
            flow = self._flow_proxy.update(landmarks, face.face_scale)

        values = np.zeros(FRAME_FEATURE_COUNT, dtype=np.float64)
        values[FRAME_INDEX["ear_left"]] = face.ear_left
        values[FRAME_INDEX["ear_right"]] = face.ear_right
        values[FRAME_INDEX["ear_mean"]] = face.ear_mean
        values[FRAME_INDEX["mouth_open_ratio"]] = face.mouth_open_ratio
        values[FRAME_INDEX["smile_ratio"]] = face.smile_ratio
        values[FRAME_INDEX["mouth_asymmetry"]] = face.mouth_asymmetry
        values[FRAME_INDEX["lip_motion"]] = face.lip_motion
        values[FRAME_INDEX["brow_raise"]] = face.brow_raise
        values[FRAME_INDEX["head_yaw"]] = face.head_yaw
        values[FRAME_INDEX["head_pitch"]] = face.head_pitch
        values[FRAME_INDEX["head_roll"]] = face.head_roll
        values[FRAME_INDEX["head_angular_speed"]] = face.head_angular_speed
        values[FRAME_INDEX["face_cx"]] = face.face_cx
        values[FRAME_INDEX["face_cy"]] = face.face_cy
        values[FRAME_INDEX["face_scale"]] = face.face_scale
        values[FRAME_INDEX["hand_present"]] = gesture.hand_present
        values[FRAME_INDEX["wrist_x"]] = gesture.wrist_x
        values[FRAME_INDEX["wrist_y"]] = gesture.wrist_y
        values[FRAME_INDEX["hand_speed"]] = gesture.hand_speed
        values[FRAME_INDEX["hand_accel"]] = gesture.hand_accel
        values[FRAME_INDEX["hand_direction"]] = gesture.hand_direction
        values[FRAME_INDEX["elbow_angle"]] = gesture.elbow_angle
        values[FRAME_INDEX["shoulder_motion"]] = gesture.shoulder_motion
        values[FRAME_INDEX["flow_mag_mean"]] = flow.mag_mean
        values[FRAME_INDEX["flow_mag_std"]] = flow.mag_std
        values[FRAME_INDEX["flow_dir_consistency"]] = flow.dir_consistency
        values[FRAME_INDEX["flow_dominant_hz"]] = flow.dominant_hz
        values[FRAME_INDEX["flow_hf_ratio"]] = flow.hf_ratio
        values = np.nan_to_num(values, nan=0.0, posinf=0.0, neginf=0.0)
        return FrameFeatures(t_s, values)
