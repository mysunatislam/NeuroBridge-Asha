# FingerSpeak ML

This package is the Python counterpart to FingerSpeak's local browser inference pipeline. It is deliberately small:

- NumPy implements the exact `20 × 63 → 20 × 98` landmark feature contract.
- DTW k-NN, nearest-prototype classification, OOD rejection, and evaluation have no heavyweight ML dependency.
- TensorFlow/Keras training and TensorFlow.js export are optional.
- The CLI validates untrusted profile JSON before any training code sees it.

Camera frames and live inference do **not** belong here. The installed web app should recognize and speak locally. Python is for reproducible experiments, evaluation, model versioning, and optional offline/cloud training from calibration landmarks a user explicitly chose to sync.

## Install

From `E:\FingerSpeak\services\ml`:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -e ".[dev]"
pytest
```

Install the heavier backend only on a training machine:

```powershell
python -m pip install -e ".[dev,tensorflow]"
```

## Commands

```powershell
fingerspeak-ml validate E:\path\profile.json --trainable
fingerspeak-ml evaluate E:\path\profile.json --model both
fingerspeak-ml train E:\path\profile.json --output E:\path\bundle
fingerspeak-ml train E:\path\profile.json --backend tensorflow --output E:\path\bundle
fingerspeak-ml export E:\path\profile.json --keras-model E:\path\model.keras --output E:\path\bundle
```

Baseline training is the default and does not import TensorFlow. `--backend tensorflow` recreates the prototype's BiGRU(24) network and exports a TensorFlow.js LayersModel alongside the baselines.

## Compatibility contract

The model manifest pins:

- feature version `3d-angle-motion-v1`
- 20 frames per sequence
- 63 raw landmark coordinates per frame
- 98 engineered features per frame
- ordered gesture names and phrases
- a canonical binary SHA-256 binding to the exact ordered training profile and samples
- confidence/dwell safety settings
- OOD centroids and spreads
- SHA-256 and size for every artifact

The web app must refuse a bundle with an unknown schema or feature version. It must also verify checksums before activation and switch model/vocabulary atomically.

The Python feature implementation mirrors the browser operation order, including population standard deviations, fingertip velocity indices, the hand-local basis, resampling grace window, and fallback spread of `0.05`. Resampling intentionally clamps interpolation to the retained frame interval, matching the current web app and fixing the legacy prototype's pre-window extrapolation. If the browser feature code changes, update `FEATURE_VERSION` and add a cross-language golden fixture before using new weights.

## Profile validation

Legacy version-2 profiles and the current version-3 web profile are accepted. Version 3 is validated as the normative trust-boundary contract: 2–24 gestures, required profile/gesture/sample fields, no additional object fields, ShortKey IDs and sessions, RFC 3339 timestamps, exact `20 × 63` bounded raw samples, and exactly one `rest` / `Rest` / empty-phrase / protected Rest record. Optional `capturedAt` timestamps survive version-3 validation and serialization. Version 2 alone retains legacy defaults, unknown-field tolerance, semantic Rest conversion, and raw-array sample conversion.

Version-3 event-sync and caregiver-alert consent choices survive validation and serialization. Landmark-sync consent is always normalized to `false`: importing a file or model bundle is never an upload-consent ceremony, and this package contains no network upload path.

The session-aware split holds out the smallest complete session for each class when two or more sessions exist. With only one session, it uses a deterministic same-session split and labels the result accordingly; that score is directional, not evidence of independent-session generalization.

## Bundle contents

```text
bundle/
  manifest.json       versioned metadata, safety configuration, metrics, checksums
  edge-prototype.json browser-readable ordered gesture IDs, centroids, and spreads
  baselines.npz       DTW samples/labels, prototypes, spreads, and OOD data
  tfjs/               present only for TensorFlow exports
    model.json
    group*-shard*.bin
```

The exact manifest, JSON artifact, NPZ layouts, integrity checks, and required browser import sequence are documented in `../../docs/MODEL_BUNDLE_CONTRACT.md` and the schemas under `../../contracts/`.

Do not store raw camera video in a model bundle. Calibration landmarks can still be sensitive health/biometric data; encrypt them at rest, apply retention limits, and sync only with explicit consent.
