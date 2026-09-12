"""NeuroBridge offline patient-adaptive intent recognition.

Pipeline::

    camera -> feature extraction -> temporal intelligence -> intent classification
           -> patient calibration -> confidence verification -> action
           -> (optional) Gemini reasoning on structured events only

The package is deliberately split so the runtime path (``pipeline``) depends only on
NumPy and the exported JSON model bundle; MediaPipe/OpenCV, scikit-learn training,
TensorFlow export, and Gemini are optional layers.
"""

from .schema import (
    BUNDLE_SCHEMA_VERSION,
    COMMAND_CLASSES,
    FRAME_FEATURES,
    FRAME_SCHEMA_VERSION,
    PROFILE_SCHEMA_VERSION,
    WINDOW_FEATURES,
    AbnormalClass,
    CalibrationPhase,
    CommandClass,
    IntentClass,
)

__all__ = [
    "BUNDLE_SCHEMA_VERSION",
    "COMMAND_CLASSES",
    "FRAME_FEATURES",
    "FRAME_SCHEMA_VERSION",
    "PROFILE_SCHEMA_VERSION",
    "WINDOW_FEATURES",
    "AbnormalClass",
    "CalibrationPhase",
    "CommandClass",
    "IntentClass",
]
__version__ = "0.1.0"
