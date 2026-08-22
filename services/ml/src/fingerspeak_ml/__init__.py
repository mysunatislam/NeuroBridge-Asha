"""FingerSpeak's shared feature pipeline and model-development utilities."""

from .classifiers import (
    DEFAULT_CONFIDENCE_THRESHOLD,
    DTWKNNClassifier,
    OODDetector,
    OODScore,
    PrototypeClassifier,
    PrototypePrediction,
    dtw_distance,
    summary_vector,
)
from .features import (
    ENGINEERED_FEATURE_LENGTH,
    FEATURE_VERSION,
    RAW_FEATURE_LENGTH,
    SEQUENCE_LENGTH,
    TimedFrame,
    add_velocity,
    build_model_input,
    compute_frame_features,
    flatten_landmarks,
    resample_sequence,
)
from .schema import Profile, ProfileValidationError, load_profile, validate_profile

__all__ = [
    "DEFAULT_CONFIDENCE_THRESHOLD",
    "ENGINEERED_FEATURE_LENGTH",
    "FEATURE_VERSION",
    "RAW_FEATURE_LENGTH",
    "SEQUENCE_LENGTH",
    "DTWKNNClassifier",
    "OODDetector",
    "OODScore",
    "Profile",
    "ProfileValidationError",
    "PrototypeClassifier",
    "PrototypePrediction",
    "TimedFrame",
    "add_velocity",
    "build_model_input",
    "compute_frame_features",
    "dtw_distance",
    "flatten_landmarks",
    "load_profile",
    "resample_sequence",
    "summary_vector",
    "validate_profile",
]

__version__ = "0.1.0"
