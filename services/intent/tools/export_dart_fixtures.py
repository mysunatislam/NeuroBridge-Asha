"""Write cross-language parity fixtures for apps/mobile/test/intent_parity_test.dart.

Usage (from services/intent):
    python tools/export_dart_fixtures.py ../../apps/mobile/test/fixtures/intent_parity.json

The Dart test recomputes every case and must match the Python reference values
within 1e-6 (window features) / 1e-9 (forest, temporal, fusion).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from neurobridge_intent.bundle import clips_to_training_data  # noqa: E402
from neurobridge_intent.features.window import window_features  # noqa: E402
from neurobridge_intent.models.abnormal import (  # noqa: E402
    AbnormalMovementDetector,
    AbnormalRuntime,
)
from neurobridge_intent.models.intent_classifier import (  # noqa: E402
    IntentClassifier,
    IntentRuntime,
)
from neurobridge_intent.models.temporal import random_runtime  # noqa: E402
from neurobridge_intent.schema import (  # noqa: E402
    FRAME_FEATURE_COUNT,
    SEQUENCE_FRAMES,
    WINDOW_FRAMES,
)
from neurobridge_intent.synthetic import (  # noqa: E402
    generate_abnormal,
    generate_command,
    generate_dataset,
)
from neurobridge_intent.verification import fuse_confidence  # noqa: E402


def main(target: str) -> None:
    rng = np.random.default_rng(42)
    cases = []
    clips = [
        generate_command(rng, "triple_blink", seconds=2.5),
        generate_command(rng, "mouth_open_hold", seconds=2.5),
        generate_abnormal(rng, "possible_seizure_like", seconds=2.5),
        generate_abnormal(rng, "involuntary", seconds=2.5),
        generate_command(rng, "non_command", seconds=2.5),
    ]
    for clip in clips:
        frames = clip.values[:WINDOW_FRAMES]
        times = clip.timestamps[:WINDOW_FRAMES]
        cases.append(
            {
                "name": f"window_{clip.command}_{clip.abnormal}",
                "timestamps": times.tolist(),
                "frames": frames.tolist(),
                "open_ear": 0.30,
                "expected": window_features(frames, timestamps=times, open_ear=0.30).tolist(),
            }
        )
    # Random frames exercise every branch (irregular timestamps, no blinks).
    random_frames = rng.normal(size=(WINDOW_FRAMES, FRAME_FEATURE_COUNT))
    random_times = np.cumsum(rng.uniform(0.04, 0.06, WINDOW_FRAMES))
    cases.append(
        {
            "name": "window_random",
            "timestamps": random_times.tolist(),
            "frames": random_frames.tolist(),
            "open_ear": None,
            "expected": window_features(random_frames, timestamps=random_times).tolist(),
        }
    )

    dataset = generate_dataset(seed=5, per_class=10)
    data = clips_to_training_data(dataset)
    intent = IntentClassifier(n_estimators=12, max_depth=6).fit(data.window_X, data.intentional)
    intent_spec = intent.export_json()
    intent_runtime = IntentRuntime(intent_spec)
    abnormal = AbnormalMovementDetector(n_estimators=12, max_depth=6).fit(
        data.window_X, data.abnormal
    )
    abnormal_spec = abnormal.export_json()
    abnormal_runtime = AbnormalRuntime(abnormal_spec)
    forest_cases = []
    for row in data.window_X[:12]:
        prediction = intent_runtime.predict(row)
        ab = abnormal_runtime.predict(row)
        forest_cases.append(
            {
                "features": row.tolist(),
                "intent": prediction.to_dict(),
                "abnormal": ab.to_dict(),
            }
        )

    temporal = random_runtime(seed=3)
    temporal_spec = {
        "type": "temporal_cnn",
        "classes": temporal.classes,
        "sequence_frames": temporal.sequence_frames,
        "channels": temporal.channels,
        "normalizer": {"mean": temporal.norm_mean.tolist(), "std": temporal.norm_std.tolist()},
        "layers": temporal.layers,
    }
    sequences = [rng.normal(size=(SEQUENCE_FRAMES, FRAME_FEATURE_COUNT)) * 0.5 for _ in range(3)]
    temporal_cases = [
        {"sequence": seq.tolist(), "expected": temporal.predict_proba(seq).tolist()}
        for seq in sequences
    ]

    fusion_cases = []
    for _ in range(20):
        args = {
            "p_command": float(rng.uniform()),
            "p_intentional": float(rng.uniform()),
            "intent_label": str(rng.choice(["intentional", "accidental", "unknown"])),
            "p_prototype": float(rng.uniform()),
            "p_abnormal": float(rng.uniform()),
            "prototype_weight": float(rng.uniform(0.0, 0.8)),
        }
        fusion_cases.append({**args, "expected": fuse_confidence(**args)})

    payload = {
        "window_cases": cases,
        "intent_spec": intent_spec,
        "abnormal_spec": abnormal_spec,
        "forest_cases": forest_cases,
        "temporal_spec": temporal_spec,
        "temporal_cases": temporal_cases,
        "fusion_cases": fusion_cases,
    }
    out = Path(target)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload), encoding="utf-8")
    print(f"wrote {out} ({out.stat().st_size / 1024:.0f} KiB)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "../../apps/mobile/test/fixtures/intent_parity.json")
