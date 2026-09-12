"""Trainable models and their portable (JSON) runtimes.

* :mod:`intent_classifier` - Phase 1 Random Forest / XGBoost / SVM on window features
* :mod:`temporal` - Phase 2 temporal CNN over 2-5 s sequences (Keras training,
  NumPy runtime, TFLite/ONNX/JSON export)
* :mod:`abnormal` - Phase 3 abnormal movement classifier with a rule-based safety floor
* :mod:`tree_export` - scikit-learn tree ensemble -> JSON + NumPy evaluator
"""

from .abnormal import AbnormalMovementDetector, rule_floor
from .intent_classifier import IntentClassifier
from .temporal import TemporalModelSpec, TemporalRuntime
from .tree_export import TreeEnsembleRuntime, export_forest

__all__ = [
    "AbnormalMovementDetector",
    "IntentClassifier",
    "TemporalModelSpec",
    "TemporalRuntime",
    "TreeEnsembleRuntime",
    "export_forest",
    "rule_floor",
]
