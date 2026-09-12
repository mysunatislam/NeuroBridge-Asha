from __future__ import annotations

import numpy as np
import pytest

from neurobridge_intent.bundle import clips_to_training_data
from neurobridge_intent.calibration import run_synthetic_calibration
from neurobridge_intent.synthetic import generate_dataset


@pytest.fixture(scope="session")
def dataset():
    return generate_dataset(seed=3, per_class=14, seconds=3.0)


@pytest.fixture(scope="session")
def training_data(dataset):
    return clips_to_training_data(dataset)


@pytest.fixture(scope="session")
def profile():
    return run_synthetic_calibration("test-patient", seed=2, seconds=15.0)


@pytest.fixture
def rng():
    return np.random.default_rng(0)
