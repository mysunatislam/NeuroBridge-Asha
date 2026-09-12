# Offline patient-adaptive intent recognition

This document describes how NeuroBridge Asha decides that a movement was a command.
The previous behaviour (`blink detected -> command`) produced false activations
from spontaneous blinks, spasms and ordinary facial movement. The replacement
treats MediaPipe / ML Kit strictly as landmark sources and makes every decision
over time, against the patient's own baseline, with an explicit confidence gate.

```
Camera input
   |
Multimodal feature extraction      28 channels per frame at 20 Hz
   |                               (eyes, mouth, brows, head pose, hand/pose, motion energy)
Temporal intelligence              2.5 s window features + 3 s sequence
   |
Intent classification              Random Forest: intentional / accidental / unknown
   |                               Temporal CNN: command pattern or non_command
Patient-specific calibration       patient_profile.json: normaliser, prototypes, thresholds
   |
Confidence verification            < 0.70 ignore, 0.70-0.90 confirm, >= 0.90 execute
   |                               abnormal movement (twitch/tremor/spasm/seizure-like) vetoes
Action execution                   speech, caption, caregiver notification
   |
(Optional) Gemini reasoning        structured JSON only, offline fallback always available
```

## Where the code lives

| Layer | Python (training, desktop, Raspberry Pi) | Dart (Android, iOS, web) |
| --- | --- | --- |
| Schema | `services/intent/src/neurobridge_intent/schema.py` | `apps/mobile/lib/intent/intent_schema.dart` |
| Features | `features/face.py`, `gesture.py`, `optical_flow.py`, `trajectory.py`, `blink.py`, `window.py` | `window_features.dart`, `frame_builder.dart` |
| Calibration | `calibration.py` | `patient_calibration_service.dart`, `patient_profile.dart`, `ui/intent_calibration_page.dart` |
| Intent classifier | `models/intent_classifier.py`, `models/tree_export.py` | `tree_ensemble.dart`, `intent_runtimes.dart` |
| Temporal model | `models/temporal.py` | `temporal_cnn.dart` |
| Abnormal movement | `models/abnormal.py` | `intent_runtimes.dart` (`AbnormalRuntime`, `ruleFloor`) |
| Verification | `verification.py` | `verification_engine.dart` |
| Pipeline | `pipeline.py` | `intent_pipeline.dart`, `intent_recognition_service.dart` |
| Gemini | `reasoning/gemini.py` | `gemini_reasoning_service.dart` |
| Export / bundle | `bundle.py`, `cli.py` | `apps/mobile/assets/models/intent_bundle_v1/` |

Cross-language parity is enforced by `services/intent/tools/export_dart_fixtures.py`
and `apps/mobile/test/intent_parity_test.dart` (window features within 1e-6, forests,
temporal CNN and confidence fusion within 1e-9).

## Phase 1 - features and the first classifier

Per frame (order pinned in the schema): `ear_left`, `ear_right`, `ear_mean`,
`mouth_open_ratio`, `smile_ratio`, `mouth_asymmetry`, `lip_motion`, `brow_raise`,
`head_yaw`, `head_pitch`, `head_roll`, `head_angular_speed`, `face_cx`, `face_cy`,
`face_scale`, `hand_present`, `wrist_x`, `wrist_y`, `hand_speed`, `hand_accel`,
`hand_direction`, `elbow_angle`, `shoulder_motion`, `flow_mag_mean`, `flow_mag_std`,
`flow_dir_consistency`, `flow_dominant_hz`, `flow_hf_ratio`.

Per 2.5 s window: mean / std / min / max / range / mean-abs-diff of every channel
(168 values) plus event features: blink count, mean duration, duration CV,
inter-blink-interval CV, blink rate, head dominant frequency and rhythmicity, face
jerk RMS and smoothness (log dimensionless jerk), hold fraction, direction
consistency, onset count, peak amplitude and sustained-movement seconds.

The intent classifier is a Random Forest by default (`--algorithm xgboost|svm` for
experiments). `unknown` is not learned: it comes from a margin threshold and an
out-of-distribution gate (z-scored distance to the training centroid), so a window
unlike anything seen in training never counts as intentional.

## Patient calibration

First-time setup records five 30-second phases: normal blinking, normal facial
movement, intentional gestures, random movement, rest. From them the profile stores
the patient's blink pattern (rate, duration, interval CV, closure depth, closing
velocity), the movement range of every channel, baseline facial activity, an
involuntary-motion profile (high-frequency ratio and rhythmicity at rest), a
per-channel normaliser, one window-feature prototype per phase, and thresholds.
The prototype weight grows with how separable the intentional phase is from the
random and rest phases. Calibration can be redone at any time from Setup, exported
as JSON for retraining, and the shipped population defaults are used until then.

## Phase 2 - temporal intelligence

Single-frame detection is not allowed. The temporal CNN reads the last 60 frames
(3 s) normalised with the patient profile and outputs one of: `non_command`,
`triple_blink`, `double_blink`, `long_blink`, `mouth_open_hold`, `smile_hold`,
`brow_raise_hold`, `head_left_hold`, `head_right_hold`, `hand_raise_hold`. A
spontaneous blink is a single short closure at random timing and stays
`non_command`; three closures within two seconds are `triple_blink`, which maps to
the help phrase by default (`command_map` in the profile).

## Phase 3 - abnormal movement

Optical flow (OpenCV Farneback on the face region on desktop/Pi; a landmark-flow
proxy from contour displacement on the phone) yields motion energy, direction
consistency, dominant frequency and the share of energy above 3 Hz. Combined with
the landmark and trajectory features, a second forest classifies the window as
`normal_voluntary`, `involuntary` (twitch/tremor), `possible_spasm` (sudden jerk,
no hold) or `possible_seizure_like` (sustained rhythmic 2.5-6.5 Hz high-amplitude
motion). A transparent rule floor can only raise the abnormal probabilities. Any
abnormal window suppresses commands; spasm and seizure-like windows raise a
caregiver alert. None of this is a diagnosis.

## Confidence verification

```
fused = p_command x gate(intent label, p_intentional) x personal(prototype) x veto(p_abnormal)
< 0.70   ignore
0.70-0.90 ask "Did you mean help?"; confirm with the confirm gesture, by repeating
          the command, or by touch within 8 s; otherwise cancel
>= 0.90  execute (per-command cooldown 3 s)
```

The Flutter app speaks the prompt, shows a Yes/No banner on the patient screen,
and only after execution hands the mapped `PatientSignal` to the existing
phrase / wheelchair caption / caregiver notification path. Legacy direct signals
still work for simulated/debug signals and the explicit seizure alert, and the
whole pipeline can be switched off in Setup.

## Phase 4 - Gemini

Gemini never receives camera data. `IntentPipeline.event_payload()` produces:

```json
{
  "patient_state": "command_triple_blink",
  "gesture": "triple_blink",
  "confidence": 0.93,
  "decision": "execute",
  "patient_history": "usually uses triple blink for assistance",
  "profile": {"patient_id": "p1", "blink_rate_per_min": 17.0, "command_map": {"...": "..."}},
  "recent_events": ["..."]
}
```

`ReasoningRequest` rejects payloads containing frames, landmarks, features or
sequences. Tasks: `summarize`, `caregiver_message`, `patient_reply`,
`long_term_patterns`. Without a key, or offline, the deterministic summary is used.

## Deployment

* **Android / iOS / web (Flutter):** the JSON bundle is a Flutter asset and runs in
  pure Dart (no platform channels), so the same models serve all three targets.
* **TensorFlow Lite:** `temporal_cnn.tflite` is exported for native Android
  integrations; `intent_rf.onnx` / `abnormal_rf.onnx` target ONNX Runtime Mobile.
* **Raspberry Pi / desktop:** `neurobridge-intent run --camera 0` uses MediaPipe
  Tasks (face, hand, pose) and OpenCV optical flow.
* **CI:** the `intent-models` job trains, exports, checks NumPy parity and verifies
  the bundle shipped in the app on every push.

## Validation before care use

The shipped models are bootstrap models trained on synthetic movement plus the
calibration protocol. Before relying on them: run calibration per patient, collect
labelled trials (commands, rest, random movement, and any involuntary movement the
care team documents), retrain with the Python toolkit, and measure false
activations over long neutral periods on the target phone. Keep an accessible
physical fallback for emergencies.
