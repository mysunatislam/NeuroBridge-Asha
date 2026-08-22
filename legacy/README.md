# FingerSpeak — a camera-based AAC prototype

A working prototype of a touchless communication tool for people who have lost speech but retain
some low-effort, voluntary finger movement (e.g. ALS, spinal cord injury, some stroke patients).
A webcam tracks the hand; a small neural network — trained live, per-user, in the browser — maps
personalized micro-gestures to spoken phrases.

**[Open `fingerspeak.html` in a browser to run it](./fingerspeak.html)** — no install, no build step,
no server. Everything runs client-side.

## Why this problem

Existing high-tech AAC (augmentative and alternative communication) mostly falls into two camps:

- **Eye-tracking systems** (e.g. Tobii Dynavox, Eyegaze) — non-invasive, but typically cap out around
  10–20 words per minute, and suffer from fatigue and lighting/reflection issues over long daily use.
- **Brain-computer interfaces** — increasingly capable (a 2026 *Nature Neuroscience* study restored
  fast bimanual typing from attempted finger movements via an implanted BCI in ALS/SCI patients), but
  require neurosurgery and are not remotely accessible to most patients today.

There's a real gap in between: patients who retain *some* finger movement — even just a twitch or a
partial range of motion in one finger — but have already lost intelligible speech. That's the target
for FingerSpeak: a $0-hardware-cost (any webcam), non-invasive, per-patient-calibrated communication
channel.

This is a **portfolio prototype**, not a validated medical device. See "What's still missing for a
real product" below for what that gap actually looks like.

## Phase 1: benchmark upgrade

FingerSpeak's next planned evolution is **NeuroBridge** — instead of recognizing a fixed set of
predefined finger gestures, discover *whatever* voluntary movement a person can still make (hands,
face, head) and adapt as that movement changes over time. That's a substantially larger effort; this
pass implements the first phase of the roadmap toward it — turning the single-model prototype into
a proper benchmark, on the existing hand-only input, so later phases (movement discovery, continual
adaptation) have a reliability foundation to build on rather than one unvalidated neural net.

What's new:

- **Two baseline classifiers alongside the BiGRU**, both operating on the exact same rotation-normalized
  features:
  - **DTW k-NN** (k=3): classifies a gesture by dynamic-time-warping distance to the nearest calibration
    examples — a strong, interpretable baseline for time-series motion.
  - **Nearest-prototype**: represents each gesture as a mean±std summary vector and classifies by
    distance to the closest class centroid — the simplest possible model, and sometimes the most stable
    one on a handful of calibration samples.
  - All three math functions (DTW, prototype summary, distance-to-nearest-prototype) were unit-tested
    standalone with synthetic sequences before integration — confirming DTW rates a time-warped version
    of the same motion as more similar than a genuinely different one, and that an out-of-distribution
    query lands meaningfully farther from every known prototype than an in-distribution one.
- **Model comparison table** (Evaluate tab): all three models are evaluated on the identical held-out
  validation sequences and reported side by side with accuracy and inference latency, so you can see
  directly whether the neural net is actually earning its complexity on your specific calibration data
  — or whether a much simpler baseline does just as well.
- **Out-of-distribution rejection**: independent of which model is driving Speak mode, a live prediction
  is rejected — treated as "unrecognized movement," not forced into the nearest known class — if it's
  too far from every calibrated gesture's prototype, regardless of how confident that model's own
  score is. This targets a specific known failure mode: a softmax (or any classifier) can be very
  confident about an input it's never actually seen before.
- **Reliability tracker** (Speak mode tab): mark false activations and missed gestures live during a
  session, and see false-activations-per-hour, missed-gesture count, phrases spoken, and median
  activation latency — the metrics that actually matter for an AAC device, as opposed to a single
  validation-accuracy number.
- **Model selector**: switch which classifier drives live Speak mode (BiGRU / DTW / nearest-prototype)
  to compare them hands-on, not just from a table.

**What this deliberately doesn't include yet** (later phases of the NeuroBridge roadmap, not started):
multi-region movement discovery (face/head/shoulders), the gesture-recommendation/separability
assistant, continual adaptation with drift detection, phrase construction, and a longitudinal
clinician view. Those are large, separable pieces of work — see the original design notes for the
full roadmap if you want to keep extending this.

## Architecture

*(Core single-model architecture below; see "Phase 1: benchmark upgrade" above for the added DTW/
nearest-prototype baselines, model comparison, and out-of-distribution rejection that now sit
alongside this BiGRU.)*

```
Webcam → MediaPipe HandLandmarker (21 3D landmarks, runs in-browser via WASM/GPU)
       → per-frame rotation-normalized feature engineering (~98 features):
           • 63 coords: each landmark re-expressed in a hand-local 3D basis (wrist = origin,
             wrist→middle-MCP = vertical axis, index-MCP→pinky-MCP = horizontal axis), so
             the same gesture looks the same regardless of hand angle or on-screen position
           • 10 finger-joint angles (MCP/PIP per finger)
           • 10 pairwise fingertip distances
           • 15 frame-to-frame fingertip velocities
       → guided calibration wizard, with capture-quality rejection (tracking coverage, hand
         too close/far) and a "New session" control so validation can be evaluated across
         genuinely different conditions, not just one sitting
       → data augmentation on raw landmarks before feature extraction (affine rotation/scale,
         time-warp, tracking-noise jitter) — 6 synthetic variants per real sample
       → session-aware train/validation split: if calibration spans 2+ sessions, validation
         uses an entirely held-out session; otherwise it falls back to a same-session split
         and the UI labels the accuracy accordingly, rather than implying more rigor than
         the data supports
       → bidirectional GRU trained in-browser via TensorFlow.js:
         BiGRU(24) over [20, 98] → dropout → dense(20) → softmax(n_classes), with early
         stopping on validation loss and best-weight restoration
       → after training: validation accuracy, a confusion matrix, and per-class precision/
         recall/F1 are rendered directly in the UI
       → live inference every ~120ms, feeding an intent state machine:
             REST → (confident, above threshold) → CANDIDATE
             CANDIDATE → held stably for a per-gesture dwell time → speaks once → WAIT_RELEASE
             WAIT_RELEASE → hand must return to Rest (or drop below threshold) for several
             consecutive ticks before another phrase can trigger
         "Rest" is a protected class that can't be deleted, since the whole trigger logic
         depends on it representing "no intent."
       → Web Speech API (with a cancel-before-speak guard) + a synthesized chime (Web Audio)
         + an animated caption banner → session log
       → model weights + gesture/phrase config can be saved/reloaded via the app's persistent
         key-value storage, so a calibration session doesn't have to be redone every visit
       → profile export/import (JSON) for calibration samples separately from the trained model
```

**Why rotation-normalized 3D features instead of raw x/y:** the original version's 42-dim
x/y-only vector meant the same gesture performed at a slightly different hand angle looked
like a different input to the model. Re-expressing every landmark in a basis built from the
hand's own geometry (wrist, middle-finger MCP, index-to-pinky line) makes the classifier robust
to camera angle and hand rotation — verified with unit tests confirming the same gesture shape
produces near-identical features regardless of rotation/translation, while genuinely different
hand shapes (e.g. open hand vs. fist) produce clearly different joint-angle features.

**Why a state machine instead of a rolling-window vote:** the earlier "6-of-8 confident frames
plus a cooldown" approach could still re-fire the same phrase repeatedly if a user held a gesture
past the cooldown window — which is exactly the kind of accidental repeat that matters most for
a real AAC device. Requiring an explicit return to Rest before the next trigger is a small UX
cost (you have to relax your hand) for a large reliability gain (no repeat-fires from holding
still), and per-gesture dwell times mean a low-stakes "Yes" can trigger faster than a high-stakes
"Emergency."

**Why the honest validation label matters:** with 5-8 samples per gesture, a random same-session
split often validates on a single example per class — enough to produce a misleadingly high or
low number, and not a meaningful test of generalization. The evaluation panel now explicitly
tells you whether its number came from a genuinely held-out session or a small same-session
split, rather than presenting both as equally rigorous.

**Why a per-user calibrated model instead of a fixed gesture classifier trained once on lots of
people?** Because the underlying clinical problem is heterogeneous — two ALS patients rarely have the
same residual movement. A generic gesture-recognition model (the kind you'd get from a MediaPipe demo)
solves the wrong problem. The actual product decision here is: **build the smallest model that can be
retrained from a handful of examples per patient**, because it needs to keep working as the disease
progresses and the deliverable movement shrinks. That's the part of this prototype worth pointing to
in an interview — not the hand tracking itself, which is a solved, off-the-shelf problem.

## Reliability rebuild (v4)

The earlier version leaned on visual polish; this pass is about recognition reliability instead —
prompted directly by a detailed external critique (included in full further down for reference).
What changed:

- **Feature engineering**: replaced the 42-dim x/y-only vector with a ~98-dim, rotation-normalized
  feature set (3D coordinates in a hand-local basis, finger-joint angles, fingertip distances,
  motion velocity). Verified with standalone unit tests before integration — same gesture at a
  different rotation/position produces near-identical features; genuinely different hand shapes
  produce clearly different joint-angle features.
- **Intent state machine**: replaced the rolling-window vote + cooldown with an explicit
  `REST → CANDIDATE → (speak once) → WAIT_RELEASE → REST` cycle. A gesture must be held stably for
  a dwell period (longer for higher-stakes gestures like "Emergency") to confirm, and the hand must
  return to Rest before the next phrase can trigger — this directly prevents the repeated/accidental
  activations a pure rolling-window approach was prone to.
- **Rest is protected**: it can no longer be deleted or renamed from the UI, since the whole trigger
  logic depends on it representing "no intent."
- **Calibration-quality rejection**: a capture is now rejected (with a specific reason shown) if
  hand-tracking coverage was too low, or the hand was too close/far from the camera, instead of
  silently accepting a bad sample.
- **Session-aware validation**: a "New session" control lets you calibrate across genuinely different
  conditions. If 2+ sessions exist, validation holds out an entire session; otherwise it falls back to
  a same-session split, and the UI **labels which kind of accuracy you're looking at**, rather than
  presenting a same-session number with the same confidence as a real generalization test.
- **Per-class precision/recall/F1**: the evaluation tab now reports these alongside the confusion
  matrix and overall accuracy — accuracy alone hides which specific gesture is unreliable.
- **Persisted trained model**: model weights and gesture/phrase config can be saved and reloaded via
  the app's built-in persistent storage, so you don't have to retrain from scratch every session
  (calibration *samples* still export/import separately as JSON, since raw samples and a trained
  model are different things worth keeping independent).

## What's still missing for a real product

Worth stating clearly, since a portfolio project should show you understand the difference between
a strong prototype and a validated product:

- **Regulatory**: an actual product here is an FDA Class II medical device (speech-generating device),
  requiring a 510(k) submission — 12–24 months, not a weekend build.
- **Clinical validation data**: this prototype's model is trained on *your* hand. A real version needs
  training/validation data from patients with actual spasticity, weakness, and tremor — behavior
  meaningfully different from a healthy calibration burst, even across multiple sessions.
- **Multi-participant testing**: everything here is single-user, self-calibrated. A real evaluation
  needs many participants, ideally with the target conditions (ALS, SCI, stroke).
- **Static vs. dynamic gesture branches**: right now every gesture goes through the same 900ms
  sequence model, whether it's a held pose ("thumbs up") or a motion (a tap). Splitting into a
  lightweight static-pose branch and a sequence branch, then combining their outputs, could improve
  both latency and accuracy — noted as a possible extension below.
- **Local/offline reliability**: this demo depends on CDN-hosted MediaPipe/TF.js assets; a bedside
  device needs everything bundled locally with no internet dependency (a PWA/service-worker
  conversion would be the natural next step).
- **Per-gesture adaptive thresholds**: the confidence threshold is currently global; some gestures
  naturally warrant a stricter or looser bar than others, derived from validation data rather than
  set by hand.

## Tech stack

- [MediaPipe Tasks Vision](https://developers.google.com/mediapipe) — hand landmark detection (WASM/GPU, in-browser)
- [TensorFlow.js](https://www.tensorflow.org/js) — model definition, training, and inference, all client-side
- Web Speech API + Web Audio API — spoken phrases and a synthesized confirmation chime
- Vanilla JS/HTML/CSS — no build step, single file, easy to read and demo

## Running it

Just open `fingerspeak.html` in a modern browser (Chrome/Edge recommended for WASM+GPU delegate
support) and grant camera permission. Nothing is uploaded anywhere — all processing is local.

1. **Calibrate**: define your gesture vocabulary (or import a saved profile), then hit
   "Start guided calibration" — it walks you through each gesture with a 3-2-1 countdown and records
   8 reps automatically, including "Rest," the protected neutral state. Use "New session" before a
   second round of calibration (different lighting/distance/position) for a meaningful evaluation.
2. **Train**: hit "Train model." This trains the BiGRU (with live epoch-by-epoch validation accuracy),
   then the DTW and nearest-prototype baselines, then evaluates all three on the same held-out data.
   Check the Evaluate tab for the labeled accuracy score, confusion matrix, per-class precision/recall/
   F1, and the model comparison table.
3. **Speak mode**: pick which model drives live recognition (BiGRU / DTW / nearest-prototype), then
   hold or perform a calibrated gesture until the confidence ring fills — that's the confirmation
   dwell. FingerSpeak speaks the phrase, chimes, and shows a caption, and won't trigger again until
   your hand returns to Rest. A movement too far from anything you calibrated is rejected outright as
   "unrecognized," regardless of the model's confidence.
4. **Track reliability**: while in Speak mode, mark false activations and missed gestures as they
   happen — the panel below shows false-activations-per-hour and median activation latency, which
   matter more for a real AAC device than a single accuracy number.
5. **Save/Load model**: persist the trained BiGRU so you can skip retraining next time (note: DTW/
   prototype comparison and out-of-distribution rejection need calibration samples, which aren't
   part of the saved model — re-import a profile to get those back). Separately, **Export/Import
   profile** saves the raw calibration samples as JSON.

## Possible extensions

Continuing the benchmark work in this pass:
- Per-gesture adaptive confidence thresholds, derived from validation data rather than a single global
  slider.
- Confidence calibration (e.g. temperature scaling) for the BiGRU's softmax output, since raw softmax
  confidence is known to be overconfident — the OOD rejection here is a blunter, distance-based
  mitigation for the same underlying problem.
- Split gestures into static (lightweight MLP on a single pose) and dynamic (sequence model) branches,
  combining their outputs — likely faster and more accurate for simple held-pose gestures.

Toward the broader NeuroBridge vision (larger, separate efforts):
- Multi-region movement discovery (face, head, shoulders) with a "controllability map" UI, so the
  system proposes which of a user's movements are most usable instead of assuming hands.
- A gesture-recommendation/separability assistant that scores candidate gestures during calibration
  and warns when two are easily confused.
- Continual adaptation: detect when a calibrated gesture's statistics have drifted (amplitude, speed,
  tracking confidence) and prompt for a couple of fresh examples rather than silently degrading.
- Phrase-construction mode ("I feel" + "severe" + "pain" + "in my chest") instead of one fixed phrase
  per gesture.
- Convert to an installable, fully offline Progressive Web App (bundle MediaPipe/TF.js assets locally,
  add a service worker) for a stricter privacy/clinical demonstration.
