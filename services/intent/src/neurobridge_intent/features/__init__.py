"""Multimodal feature extraction layer.

MediaPipe (or ML Kit on the phone) is used *only* as a landmark source. The modules
here turn landmarks, hand/pose points and optical flow into the bounded numeric
channels defined in :mod:`neurobridge_intent.schema`. No image data is retained.
"""

from .blink import BlinkDetector, BlinkEvent, blink_statistics
from .face import FaceFeatureExtractor, FaceMetrics, eye_aspect_ratio, mouth_metrics
from .gesture import GestureFeatureExtractor, GestureMetrics, joint_angle
from .optical_flow import FlowMetrics, FlowSeriesAnalyzer, OpticalFlowAnalyzer
from .trajectory import TrajectoryAnalyzer, TrajectoryMetrics, segment_phases
from .window import FeatureWindow, FrameFeatures, window_features

__all__ = [
    "BlinkDetector",
    "BlinkEvent",
    "FaceFeatureExtractor",
    "FaceMetrics",
    "FeatureWindow",
    "FlowMetrics",
    "FlowSeriesAnalyzer",
    "FrameFeatures",
    "GestureFeatureExtractor",
    "GestureMetrics",
    "OpticalFlowAnalyzer",
    "TrajectoryAnalyzer",
    "TrajectoryMetrics",
    "blink_statistics",
    "eye_aspect_ratio",
    "joint_angle",
    "mouth_metrics",
    "segment_phases",
    "window_features",
]
