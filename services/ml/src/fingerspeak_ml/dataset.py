"""Dataset preparation and session-aware validation splits."""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
from numpy.typing import NDArray

from .features import ENGINEERED_FEATURE_LENGTH, SEQUENCE_LENGTH, build_model_input
from .schema import CalibrationSample, Profile

FloatArray = NDArray[np.float64]
IntArray = NDArray[np.int64]


@dataclass(frozen=True, slots=True)
class DatasetSplit:
    class_names: tuple[str, ...]
    train_x: FloatArray
    train_y: IntArray
    validation_x: FloatArray
    validation_y: IntArray
    train_sequences_by_class: tuple[tuple[FloatArray, ...], ...]
    validation_sequences_by_class: tuple[tuple[FloatArray, ...], ...]
    all_session_based: bool
    held_out_sessions: tuple[str | None, ...]

    @property
    def has_validation(self) -> bool:
        return self.validation_x.shape[0] > 0


def _stack(sequences: list[FloatArray]) -> FloatArray:
    if not sequences:
        return np.empty(
            (0, SEQUENCE_LENGTH, ENGINEERED_FEATURE_LENGTH), dtype=np.float64
        )
    return np.stack(sequences)


def _same_session_split(
    samples: tuple[CalibrationSample, ...],
    validation_fraction: float,
    rng: np.random.Generator,
) -> tuple[list[CalibrationSample], list[CalibrationSample]]:
    shuffled = list(samples)
    rng.shuffle(shuffled)
    if len(shuffled) >= 4:
        # JavaScript Math.round rounds .5 upward; Python round uses bankers' rounding.
        validation_count = max(1, math.floor(len(shuffled) * validation_fraction + 0.5))
    else:
        validation_count = 0
    return shuffled[validation_count:], shuffled[:validation_count]


def session_aware_split(
    profile: Profile,
    *,
    validation_fraction: float = 0.2,
    seed: int = 0,
) -> DatasetSplit:
    """Reproduce the browser's per-class, session-aware train/validation split.

    When a gesture has samples from multiple sessions, its smallest session is
    held out in full. Otherwise, a deterministic same-session random split is
    used and the result is explicitly marked as weaker evidence.
    """

    if not 0.0 < validation_fraction < 1.0:
        raise ValueError("validation_fraction must be between zero and one")
    if len(profile.gestures) < 2:
        raise ValueError("a trainable dataset requires at least two gestures")
    if any(not gesture.samples for gesture in profile.gestures):
        missing = [gesture.name for gesture in profile.gestures if not gesture.samples]
        raise ValueError(f"every gesture needs at least one sample: {', '.join(missing)}")

    generator = np.random.default_rng(seed)
    train_sequences: list[FloatArray] = []
    train_labels: list[int] = []
    validation_sequences: list[FloatArray] = []
    validation_labels: list[int] = []
    train_by_class: list[tuple[FloatArray, ...]] = []
    validation_by_class: list[tuple[FloatArray, ...]] = []
    held_out_sessions: list[str | None] = []
    all_session_based = True

    for class_index, gesture in enumerate(profile.gestures):
        by_session: dict[str, list[CalibrationSample]] = {}
        for sample in gesture.samples:
            by_session.setdefault(sample.session, []).append(sample)
        if len(by_session) >= 2:
            # Stable min preserves first-seen session order for equal sample counts,
            # matching the stable sort used by modern JavaScript engines.
            held_out, validation_samples = min(
                by_session.items(), key=lambda pair: len(pair[1])
            )
            validation_identity = {id(sample) for sample in validation_samples}
            training_samples = [
                sample for sample in gesture.samples if id(sample) not in validation_identity
            ]
            validation_samples = list(validation_samples)
            held_out_sessions.append(held_out)
        else:
            all_session_based = False
            training_samples, validation_samples = _same_session_split(
                gesture.samples, validation_fraction, generator
            )
            held_out_sessions.append(None)

        if not training_samples:
            raise ValueError(f"split left gesture {gesture.name!r} with no training samples")
        class_train = tuple(
            build_model_input(sample.raw, require_sequence_length=True)
            for sample in training_samples
        )
        class_validation = tuple(
            build_model_input(sample.raw, require_sequence_length=True)
            for sample in validation_samples
        )
        train_by_class.append(class_train)
        validation_by_class.append(class_validation)
        train_sequences.extend(class_train)
        train_labels.extend([class_index] * len(class_train))
        validation_sequences.extend(class_validation)
        validation_labels.extend([class_index] * len(class_validation))

    return DatasetSplit(
        class_names=profile.class_names,
        train_x=_stack(train_sequences),
        train_y=np.asarray(train_labels, dtype=np.int64),
        validation_x=_stack(validation_sequences),
        validation_y=np.asarray(validation_labels, dtype=np.int64),
        train_sequences_by_class=tuple(train_by_class),
        validation_sequences_by_class=tuple(validation_by_class),
        all_session_based=all_session_based,
        held_out_sessions=tuple(held_out_sessions),
    )


def all_sequences_by_class(profile: Profile) -> tuple[tuple[FloatArray, ...], ...]:
    """Featurize every validated sample, preserving gesture/class order."""

    output: list[tuple[FloatArray, ...]] = []
    for gesture in profile.gestures:
        if not gesture.samples:
            raise ValueError(f"gesture {gesture.name!r} has no samples")
        output.append(
            tuple(
                build_model_input(sample.raw, require_sequence_length=True)
                for sample in gesture.samples
            )
        )
    return tuple(output)
