# FingerSpeak model bundle contract v1

The Python ML service exports a directory with two artifacts required for browser prototype inference:

```text
manifest.json
edge-prototype.json
```

It also contains `baselines.npz` for Python evaluation and may contain a `tfjs/` model in future TensorFlow-enabled builds. A browser prototype loader does not need to parse NPZ or load TensorFlow.

The normative schemas are:

- `contracts/model-bundle-v1.schema.json`
- `contracts/edge-prototype-v1.schema.json`

## Manifest

`manifest.json` uses `schema_version: 1`. Its feature contract is fixed to:

```json
{
  "version": "3d-angle-motion-v1",
  "sequence_length": 20,
  "raw_feature_length": 63,
  "engineered_feature_length": 98
}
```

`training_profile_sha256` is the lowercase SHA-256 of the exact ordered profile data used to fit the model. The browser must recompute it from the active profile and reject the bundle if it differs.

`classes` is ordered by model class index. Every entry contains:

- `index`: zero-based contiguous class index
- `gesture_id`: stable web profile gesture ID; Rest is always `rest`
- `name`, `phrase`, `icon`, `risk`, and `dwell_ms`
- `is_rest`: exactly one entry is true
- `confidence_threshold`: exactly `0.72`

The `models` entry with `type: "nearest-prototype"` points to `edge-prototype.json`. The `ood` entry points to the same artifact and pins multiplier `2.2`.

Every profile, manifest, and edge-artifact gesture ID uses the API/browser ShortKey contract `^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$`: 1-80 ASCII characters, beginning with an alphanumeric character, with alphanumerics, underscores, dots, and hyphens allowed afterward.

Every file is listed under `artifacts` with its POSIX-relative path, byte length, and lowercase SHA-256 of the exact file bytes. Artifact paths must remain relative and must not contain a `..` segment.

## Training-profile binding

The canonical profile-binding byte stream is versioned independently by its magic prefix. Integers are unsigned 32-bit little-endian. String lengths count UTF-8 bytes, not characters. Raw coordinates are IEEE-754 float64 little-endian in frame-major, coordinate-major order.

```text
ASCII "fingerspeak-profile-binding-v1" + NUL
uint32 gesture_count
for each gesture in profile order:
  utf8 gesture_id       # uint32 byte_length, then bytes
  utf8 name
  utf8 phrase
  utf8 risk
  uint32 dwell_ms
  uint32 sample_count
  for each sample in stored order:
    utf8 session
    float64_le raw[20][63]
```

Resolve gesture IDs before encoding exactly as the bundle does: semantic Rest is `rest`; a missing legacy non-Rest ID is `gesture-{n}`, where `n` is its one-based index in the original gesture array. Dimensions are fixed by the contract and are not encoded. Profile name/ID/version, icons, protection flags, consent, timestamps including `capturedAt`, and every other unlisted field are excluded.

The cross-runtime golden vector contains two one-sample gestures: `rest / Rest / "" / routine / 650 / s1` with 20 × 63 positive zeros, followed by `yes.v1 / Yes / Yes. / clinical / 1000 / s2` with positive zeros except `raw[0][0] = 1.5` and `raw[19][62] = -2.25`.

```text
encoded length: 20291 bytes
sha256: 3e4bf74ae01df86b64e4df133b78090e01017f6f3eacc7c1c314dc8690667332
```

## Browser edge artifact

`edge-prototype.json` contains:

```json
{
  "schema_version": 1,
  "feature": {
    "version": "3d-angle-motion-v1",
    "sequence_length": 20,
    "feature_length": 98,
    "summary_length": 196
  },
  "confidence_threshold": 0.72,
  "ood_multiplier": 2.2,
  "prototypes": [
    {
      "gesture_id": "rest",
      "centroid": ["196 finite numbers"],
      "spread": 0.05
    }
  ]
}
```

Prototype order must exactly equal manifest class order. A centroid is `mean[98] + populationStdDev[98]`. `spread` is the average Euclidean distance of calibration summaries from the class centroid, floored to `0.05`.

Inference selects the prototype with the smallest **absolute** Euclidean distance. For that selected class only:

```text
normalizedDistance = distance / spread
confidence = 1 / (1 + normalizedDistance)
inDistribution = distance <= spread * 2.2
candidate = inDistribution && confidence >= 0.72
```

Do not select a class using normalized distance; spread is applied only after absolute-nearest selection.

## Required browser import sequence

1. Ask the user for both `manifest.json` and the referenced `edge-prototype.json`.
2. Parse and validate the manifest before trusting any path or metadata.
3. Find the `nearest-prototype` model entry and matching artifact descriptor.
4. Verify the edge artifact byte length and SHA-256 with `crypto.subtle.digest("SHA-256", bytes)` before JSON parsing.
5. Validate the edge schema, finite centroid values, 196-value centroid length, spread floor, and pinned constants.
6. Recompute the canonical active-profile digest and compare it to `training_profile_sha256` using exact lowercase hexadecimal equality.
7. Require edge prototype IDs and order to exactly match `manifest.classes[*].gesture_id`.
8. Require those IDs to match the active profile, or import the manifest vocabulary and model atomically. Never bind by display name or array position alone.
9. Convert the artifact to the web `PrototypeModel` shape and save profile/model together in one IndexedDB transaction. Do not activate a partially imported model.
10. Keep the previous active model if any check fails.

Model bundles contain no raw landmarks and no consent flags. Importing one must never enable landmark upload, analytics, or caregiver messaging. Consent remains device/profile state governed by the profile import flow.

## NPZ layout

`baselines.npz` is for Python/offline analysis and contains unpickled numeric NumPy arrays only:

| Key | dtype | shape | Meaning |
| --- | --- | --- | --- |
| `dtw_sequences` | float64 | `(N, 20, 98)` | Ordered DTW training sequences |
| `dtw_labels` | int64 | `(N,)` | Zero-based class labels |
| `dtw_k` | int64 | `(1,)` | Neighbor count, currently 3 |
| `prototype_centroids` | float64 | `(C, 196)` | Ordered class summary centroids |
| `prototype_spreads` | float64 | `(C,)` | Ordered spreads, each at least 0.05 |
| `ood_centroids` | float64 | `(C, 196)` | Ordered OOD centroids |
| `ood_spreads` | float64 | `(C,)` | Ordered OOD spreads, each at least 0.05 |
| `ood_multiplier` | float64 | `(1,)` | Rejection multiplier, exactly 2.2 |

`C` equals `manifest.classes.length`; `N` is the total number of real training samples. Browser code should use `edge-prototype.json`, not add an NPZ parser.
