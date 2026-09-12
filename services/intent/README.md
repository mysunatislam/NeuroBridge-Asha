# neurobridge-intent

Offline, patient-adaptive intent recognition for the NeuroBridge Asha assistant.
**Movement is not a command.** MediaPipe (desktop/Raspberry Pi) and ML Kit (phone)
only extract landmarks; every command decision is made over a 2-5 second window by
a chain of small offline models plus a patient-specific profile and a confidence
gate.

```
Camera -> feature extraction -> temporal intelligence -> intent classification
       -> patient calibration -> confidence verification -> action
       -> (optional) Gemini reasoning over structured events only
```

| Phase | Module | What it does |
| --- | --- | --- |
| 1 | `features/*`, `models/intent_classifier.py` | 28 per-frame channels (EAR, blink timing, mouth/smile/asymmetry, brow, head pose and angular speed, wrist/elbow/shoulder, optical-flow energy); 182 window features; Random Forest / XGBoost / SVM -> intentional, accidental, unknown |
| 1 | `calibration.py` | five 30 s recordings -> `patient_profile.json` (blink pattern, movement range, baseline activity, involuntary profile, normaliser, phase prototypes, thresholds) |
| 2 | `models/temporal.py` | temporal CNN over the last 3 s -> command pattern (`triple_blink`, `long_blink`, `mouth_open_hold`, ...) or `non_command`; Keras training, NumPy runtime, TFLite/ONNX/JSON export |
| 3 | `features/optical_flow.py`, `features/trajectory.py`, `models/abnormal.py` | Farneback flow + landmark + temporal features -> normal voluntary, involuntary, possible spasm, possible seizure-like; transparent rule floor that can only raise abnormal probability |
| 4 | `verification.py`, `reasoning/gemini.py` | fused confidence: < 0.70 ignore, 0.70-0.90 ask for confirmation, >= 0.90 execute; abnormal movement always vetoes; Gemini receives only structured JSON and always has an offline fallback |

The Flutter app (`apps/mobile/lib/intent`) contains a line-by-line Dart port of the
runtime pieces (window features, forests, temporal CNN, verification, calibration).
`tools/export_dart_fixtures.py` produces the parity fixtures that
`apps/mobile/test/intent_parity_test.dart` checks.

## Install

```bash
python -m pip install -e "services/intent[dev]"                 # NumPy + scikit-learn runtime
python -m pip install -e "services/intent[vision]"              # MediaPipe + OpenCV camera extractor
python -m pip install -e "services/intent[tensorflow,onnx]"     # temporal CNN training, TFLite/ONNX export
```

## Commands

```bash
neurobridge-intent train --output models/intent_bundle_v1            # bootstrap models + export
neurobridge-intent verify models/intent_bundle_v1                     # checksums + schema
neurobridge-intent export-app --bundle models/intent_bundle_v1 \
    --output ../../apps/mobile/assets/models/intent_bundle_v1      # JSON-only copy for the app
neurobridge-intent models fetch                                       # MediaPipe .task files (once)
neurobridge-intent calibrate --patient-id p1 --output patient_profile.json --camera 0
neurobridge-intent run --bundle models/intent_bundle_v1 --profile patient_profile.json --camera 0
neurobridge-intent run --bundle models/intent_bundle_v1 --synthetic   # no camera needed
neurobridge-intent reason --payload event.json --task caregiver_message   # optional Gemini layer
```

`GEMINI_API_KEY` enables the reasoning layer; without it (or offline) every call
returns the deterministic summary instead. Raw frames, landmarks or feature vectors
are rejected by `ReasoningRequest` before anything is sent.

## Bundle layout

```
models/intent_bundle_v1/
  manifest.json        schema versions, metrics, sha256 of every file
  intent_rf.json       Phase 1 forest + OOD gate           (Dart / NumPy runtime)
  temporal_cnn.json    Phase 2 weights                     (Dart / NumPy runtime)
  temporal_cnn.tflite  Phase 2 for TensorFlow Lite         (Android native / edge)
  abnormal_rf.json     Phase 3 forest + rule floor         (Dart / NumPy runtime)
  intent_rf.onnx, abnormal_rf.onnx                         (ONNX Runtime Mobile)
```

The JSON files are copied to `apps/mobile/assets/models/intent_bundle_v1/` and
loaded by the Flutter runtime on Android, iOS and web.

## Data

The shipped bootstrap models are trained on physiologically-motivated synthetic
movement (`synthetic.py`: Poisson spontaneous blinks, ramp-hold-release commands,
4-12 Hz tremor bursts, jerk-decay spasms, sustained 2.5-6 Hz seizure-like
oscillation, random wandering). They exist so the pipeline, the parity tests and CI
run without patient data. Real patient recordings arrive through the calibration
protocol (the app can export them as JSON) and should be added to training before
any care use. Nothing here diagnoses a condition; the abnormal-movement classes gate
commands and raise a caregiver alert for review.

## Tests

```bash
python -m pytest -q services/intent/tests
python -m ruff check services/intent
```
