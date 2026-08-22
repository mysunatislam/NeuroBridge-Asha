from __future__ import annotations

import copy

import numpy as np
import pytest


def base_hand() -> np.ndarray:
    return np.asarray(
        [
            [0.00, 0.00, 0.00],
            [-0.18, 0.20, 0.00],
            [-0.32, 0.38, 0.02],
            [-0.45, 0.57, 0.04],
            [-0.52, 0.76, 0.06],
            [-0.22, 0.43, 0.00],
            [-0.24, 0.72, 0.02],
            [-0.25, 0.98, 0.04],
            [-0.26, 1.22, 0.08],
            [0.00, 0.50, 0.00],
            [0.00, 0.84, 0.01],
            [0.00, 1.13, 0.03],
            [0.00, 1.40, 0.05],
            [0.20, 0.46, 0.00],
            [0.22, 0.77, 0.01],
            [0.24, 1.01, 0.02],
            [0.26, 1.23, 0.03],
            [0.38, 0.38, 0.00],
            [0.44, 0.64, 0.01],
            [0.49, 0.84, 0.02],
            [0.53, 1.01, 0.03],
        ],
        dtype=np.float64,
    )


def make_raw_sequence(kind: int = 0, variant: float = 0.0) -> np.ndarray:
    output = []
    for frame_index in range(20):
        points = base_hand()
        phase = frame_index / 19
        points[:, 2] += variant * 0.002
        if kind == 0:  # Rest: tiny tracking-scale drift only.
            points[8, 0] += variant * 0.004 * phase
        elif kind == 1:  # A deliberate index curl.
            points[7] += [0.03 * phase, -0.12 * phase, 0.04 * phase]
            points[8] += [0.10 * phase, -0.42 * phase, 0.12 * phase]
        elif kind == 2:  # A different pinky motion.
            points[19] += [-0.02 * phase, -0.08 * phase, 0.03 * phase]
            points[20] += [-0.12 * phase, -0.30 * phase, 0.08 * phase]
        else:
            raise ValueError("unknown synthetic gesture")
        output.append(points.reshape(-1))
    return np.stack(output)


def make_profile_payload(*, sessions: tuple[str, ...] = ("s1", "s2")) -> dict:
    gestures = []
    definitions = (("g_rest", "Rest", "", 0), ("g_yes", "Yes", "Yes.", 1))
    for identifier, name, phrase, kind in definitions:
        samples = []
        for session_index, session in enumerate(sessions):
            for repetition in range(2):
                samples.append(
                    {
                        "session": session,
                        "raw": make_raw_sequence(
                            kind, variant=session_index * 2 + repetition
                        ).tolist(),
                    }
                )
        gestures.append(
            {
                "id": identifier,
                "name": name,
                "phrase": phrase,
                "icon": "hand",
                "protected": name == "Rest",
                "samples": samples,
            }
        )
    return {"version": 2, "gestures": gestures}


def make_profile_v3_payload(*, sessions: tuple[str, ...] = ("s1", "s2")) -> dict:
    """Return the canonical valid profile-v3 trust-boundary fixture."""

    payload = make_profile_payload(sessions=sessions)
    payload.update(
        version=3,
        id="local-profile",
        name="My communication profile",
        consentToEventSync=False,
        consentToCaregiverAlerts=False,
        consentToLandmarkSync=False,
        updatedAt="2026-08-15T10:00:00.000Z",
    )
    for gesture in payload["gestures"]:
        is_rest = gesture["name"] == "Rest"
        gesture["id"] = "rest" if is_rest else gesture["id"]
        gesture["risk"] = "routine" if is_rest else "clinical"
        gesture["dwellMs"] = 500 if is_rest else 1000
    payload["gestures"][1]["samples"][0]["capturedAt"] = (
        "2026-08-15T09:30:45.123Z"
    )
    return payload


@pytest.fixture
def raw_sequence() -> np.ndarray:
    return make_raw_sequence(kind=1)


@pytest.fixture
def profile_payload() -> dict:
    return make_profile_payload()


@pytest.fixture
def profile_v3_payload() -> dict:
    return make_profile_v3_payload()


@pytest.fixture
def copied_profile_payload(profile_payload: dict) -> dict:
    return copy.deepcopy(profile_payload)
