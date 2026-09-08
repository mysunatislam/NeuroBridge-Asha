# UX Audit — NeuroBridge Asha
**Version:** 2.5 (MVP Mobile App)  
**Audit Date:** September 2026  
**Auditor:** UX Research Team  
**Frameworks:** Nielsen's 10 Usability Heuristics · Fitts's Law · Hick's Law · Jakob's Law · Gestalt Principles  
**Scope:** Role Selection → Patient Dashboard → Caregiver Hub → Calibration Wizard → Hand Studio  

---

## Executive Summary

NeuroBridge Asha is a clinically sensitive AAC (Augmentative and Alternative Communication) app for patients with severe motor disabilities. Its users are among the most vulnerable in UX: patients who may have no fine motor control, caregivers who operate under stress, and clinicians who need zero cognitive friction. This audit identified **7 Critical**, **9 Major**, and **8 Minor** issues across all five core screens.

The most severe issues involve the **calibration entry point** (a critical task buried under a non-descriptive label), **emergency SOS confirmation friction** (a dialog that delays a life-critical action), and **Hick's Law violations** in the Calibration Wizard (19 signal types presented simultaneously). These must be resolved before clinical deployment.

---

## Severity Scale

| Level | Definition |
|-------|-----------|
| 🔴 **Critical** | Blocks primary task or creates safety risk. Fix before any release. |
| 🟠 **Major** | Significantly degrades usability for the core user group. Fix in next sprint. |
| 🟡 **Minor** | Friction or polish issue. Address in upcoming releases. |

---

## Prioritized Issue List

### 🔴 CRITICAL Issues

---

#### C-1 · Emergency SOS Requires Confirmation Dialog Before Acting

**Screen:** Patient Dashboard (`patient_page.dart` line 288–308)  
**Heuristic Violated:** #5 — Error Prevention; #10 — Help & Documentation  
**UX Law Violated:** Fitts's Law (time-sensitive action); User safety  

**Observation:**  
Tapping "Emergency Help SOS" triggers an `AlertDialog` asking the user to confirm before any action occurs. For a patient using only blinks or micro-expressions — each requiring deliberate motor effort — this confirmation dialog represents a potentially lethal delay. The dialog text is also dense (4-line paragraph) and requires two distinct target acquisitions (Cancel vs. Request Emergency Help button) under panic conditions.

```dart
// patient_page.dart:288
final confirmed = await showDialog<bool>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('Request emergency help?'),
    content: const Text(
      'This will speak the urgent request aloud, show it on the wheelchair display...',
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
      FilledButton(..., child: const Text('Request Emergency Help')),
    ],
  ),
);
```

**Fix:**  
Replace confirmation dialog with a **press-and-hold gesture** (1.5s hold trigger) on the SOS button with a visible countdown arc. No modal. Provide an "Undo" snackbar for 5 seconds post-trigger to cancel unintended activations. For blink/face users, a **double-blink confirmation** pattern eliminates the need for any dialog.

```dart
// Proposed: GestureDetector with longPress + haptic
GestureDetector(
  onLongPress: () => _executeEmergencyHelp(), // no dialog
  child: AnimatedSosButton(), // shows radial countdown on hold
)
```

---

#### C-2 · "Calibrate" Button Label Fails to Communicate Scope or Consequence

**Screen:** Caregiver Hub (`caregiver_page.dart` line 319–327)  
**Heuristic Violated:** #2 — Match Between System and Real World; #6 — Recognition vs. Recall  
**UX Law Violated:** Jakob's Law (label doesn't follow medical AAC conventions)  

**Observation:**  
The MediaPipe Hand Gesture Suite card shows a single `FilledButton` labeled **"Calibrate"**. This label is ambiguous — caregivers on first use don't know whether this is a one-time setup, a test, a recalibration, or whether it wipes existing data. The subtitle "98-Feature 3D DTW & Prototype Calibrator" is technical jargon inaccessible to non-engineering users. There is no indicator of whether calibration has already been done.

**Fix:**  
- Change button label to **"Train Hand Gestures"** (first use) / **"Manage Saved Gestures"** (after gestures exist).
- Replace subtitle with: *"Teaches Asha to recognize the patient's hand signs."*
- Add a green "✓ 3 gestures trained" badge when gestures exist, or an amber "Not set up yet" indicator when empty.
- Show a note: *"This will add to (not replace) existing gestures."*

---

#### C-3 · Input Method Selection Dialog at First Launch Is Non-Dismissible and Inaccessible

**Screen:** Patient Dashboard first launch (`patient_page.dart` line 152–198)  
**Heuristic Violated:** #3 — User Control and Freedom; #4 — Consistency and Standards  
**UX Law Violated:** Hick's Law (3 choices in an unfamiliar modal with no preview)  

**Observation:**  
On first launch, `_askFingerCapability()` shows a non-dismissible `AlertDialog` (`barrierDismissible: false`) with three actions: "Ability Assessment", "No — use face & eyes", "Yes — use fingers". The patient may be entirely unable to tap a dialog due to their condition. The dialog background color `0xFF1E293B` (very dark) against the app's light theme creates a jarring, inconsistent experience.

**Fix:**  
- Surface this as a full onboarding screen (not a modal) with illustrations of each input mode.
- Move this choice to the **Caregiver setup flow** so it is configured before the patient uses the device.
- Allow dismissal with graceful "Not configured" state fallback.

---

#### C-4 · Calibration Wizard Presents 19 Signal Types Simultaneously (Hick's Law Violation)

**Screen:** Calibration Wizard Steps 2–4 (`calibration_wizard_page.dart` lines 1000–1120)  
**Heuristic Violated:** #8 — Aesthetic and Minimalist Design  
**UX Law Violated:** Hick's Law — decision time grows logarithmically with number of choices  

**Observation:**  
Steps 2, 3, and 4 of the Calibration Wizard present **6, 5, and 3 coach cards simultaneously** in an undifferentiated vertical list. A caregiver must understand the difference between "Blink", "Rapid Blink", "Slow Blink", "Eye Tremor", "Left Wink", "Right Wink" — all on the same screen — without clinical guidance on which signals suit which conditions (ALS vs. stroke vs. cerebral palsy).

**Fix:**  
- Reduce to **3 recommended signals per wizard step** with "Show more" expansion.
- Pre-select signals based on the patient's ability profile from `AbilityAssessmentPage`.
- Add a **"Recommended for [condition]" label** tied to profile data.
- Collapse non-recommended signals into: *"Advanced signals (for experienced caregivers)"*.

---

#### C-5 · Patient Camera Feed Has No Actionable "Face Not Detected" Recovery Path

**Screen:** Patient Dashboard + Calibration Wizard  
**Heuristic Violated:** #1 — Visibility of System Status; #9 — Help Recover from Errors  

**Observation:**  
When face detection fails, both screens show a static icon and a status message string. There is no repositioning tip, no camera permission check prompt, no illustration of correct framing, and no direct recovery action on screen. The AppBar refresh button is the only restart mechanism — easy to miss.

**Fix:**  
- Show an animated guide overlay: translucent face outline on the camera feed indicating correct framing.
- Display contextual steps: *"1. Ensure room is well lit. 2. Position camera at eye level. 3. Stay within 40–60 cm."*
- Add a **Retry Camera** button directly in the empty-state widget.

---

#### C-6 · Hand Studio Has No Accessible Back-Navigation in Patient Mode

**Screen:** Hand Calibration Page (`hand_calibration_page.dart`)  
**Heuristic Violated:** #3 — User Control and Freedom  
**UX Law Violated:** Fitts's Law — OS back arrow is unreachable for face/eye/switch users  

**Observation:**  
`HandCalibrationPage` in `patientExecution` mode shows only the standard Flutter back arrow in the AppBar. For patients using face/eye-based navigation or single-switch scanning, this is completely unreachable with no alternative exit affordance.

**Fix:**  
- In `patientExecution` mode, add a large `FloatingActionButton` or full-width bottom button: **"Done / Return to Dashboard"** with at least 64px height (Fitts's Law compliance).
- For single-switch users, auto-route back after a configurable inactivity timeout.

---

#### C-7 · "Connect Patient Profile ID" Requires Raw UUID Entry With No Guidance

**Screen:** Caregiver Hub (`caregiver_page.dart` lines 440–454)  
**Heuristic Violated:** #5 — Error Prevention; #2 — Match Between System and Real World  
**UX Law Violated:** Jakob's Law — UUIDs are not a familiar pattern for non-technical caregivers  

**Observation:**  
The cloud connection card asks caregivers to "Enter the patient's profile UUID". UUIDs are completely foreign to nurses, family caregivers, and community health workers. There is no format hint, no inline validation, no QR scan option, and no help link.

**Fix:**  
- Add a **"Scan QR Code"** button as the primary action; manual UUID entry as secondary.
- Show a format hint: *"Should look like: 8a3f-... (36 characters)"*.
- Add inline validation with a green checkmark when the format is valid.
- Add a help tooltip: *"Ask the patient's NeuroBridge clinic for their profile ID."*

---

### 🟠 MAJOR Issues

---

#### M-1 · Role Selection Has No Guest / Demo Mode

**Screen:** Role Selection (`role_selection_page.dart`)  
**Heuristic Violated:** #1 — Visibility of System Status  
**Observation:** Clinicians evaluating the app must commit to a role and go through full setup before seeing any functionality. There is no exploration path.  
**Fix:** Add a **"Try Demo Mode"** option below the role cards with sample data pre-loaded.

---

#### M-2 · Emergency Button and Routine Buttons Have Identical Visual Weight

**Screen:** Patient Dashboard  
**Heuristic Violated:** #8 — Aesthetic and Minimalist Design  
**UX Law Violated:** Gestalt — figure-ground: critical actions not visually differentiated  
**Observation:** "Emergency Help SOS" FilledButton (`0xFFB42318`, 56px) and "Call My Caregiver" FilledButton use the same height, padding, and font size. Under stress, users must visually parse which button is which.  
**Fix:** Emergency SOS should be 72px tall with a pulsing border animation. "Call Caregiver" should be an OutlinedButton to create clear hierarchy.

---

#### M-3 · No Undo for "Clear Local" Alert History

**Screen:** Caregiver Hub (`caregiver_page.dart` line 726–733)  
**Heuristic Violated:** #3 — User Control and Freedom  
**Observation:** Permanently deletes local alert log with no confirmation or undo. A clinician may accidentally wipe distress event history.  
**Fix:** Use a snackbar with "Undo" (5s) or soft-delete with restore option.

---

#### M-4 · Coaching Countdown (5 Seconds) Too Short for Patients With Motor Delay

**Screen:** Calibration Wizard (`calibration_wizard_page.dart` line 269)  
**Heuristic Violated:** #7 — Flexibility and Efficiency of Use  
**UX Law Violated:** Fitts's Law — motor execution for disabled users far exceeds 5 seconds  
**Observation:** For ALS-stage patients, even a deliberate blink can take 3–4 seconds to initiate. The timer doesn't pause on failure and doesn't auto-retry.  
**Fix:** Default to **15 seconds** with a visible progress arc. Make configurable (10s / 20s / 30s) in Settings.

---

#### M-5 · Sensitivity Slider Has No Contextual Anchors

**Screen:** Calibration Wizard Step 6 (`calibration_wizard_page.dart` lines 1209–1214)  
**Heuristic Violated:** #2 — Match Between System and Real World  
**Observation:** Raw percentage 40–95% with 11 divisions. Caregivers don't know whether 75% is appropriate for tremors or intentional blinks.  
**Fix:** Replace with semantic labels: `Low (40%)` · `Medium (75%)` · `High (95%)`. Add contextual note: *"Raise for strong intentional movements. Lower for weak or tremor-affected muscle control."*

---

#### M-6 · Character Count Feedback Missing Until Text Field Limit Is Hit

**Screen:** Caregiver Hub (`caregiver_page.dart` line 636–644)  
**Heuristic Violated:** #1 — Visibility of System Status  
**Observation:** `maxLength: 280` counter appears only at the bottom of the field. No progressive feedback.  
**Fix:** Show live counter *"244/280"* with amber >250, red >270 color shift.

---

#### M-7 · Camera Loading Screen Has No Timeout or Forced-Retry

**Screen:** Hand Calibration Page (`hand_calibration_page.dart` lines 150–166)  
**Heuristic Violated:** #1 — Visibility of System Status; #9 — Error Recovery  
**Observation:** If camera release hangs, user is permanently stuck with a spinner. No timeout, no escape.  
**Fix:** Add 10-second timeout that triggers error state and shows: *"Camera took too long. Tap to retry."*

---

#### M-8 · Preset Caption Chips Auto-Send Without Preview

**Screen:** Caregiver Hub (`caregiver_page.dart` lines 651–680)  
**Heuristic Violated:** #5 — Error Prevention  
**Observation:** Tapping a chip populates the field AND immediately calls `_sendCaption()`. Accidental tap sends a message to the patient's wheelchair display immediately.  
**Fix:** Chips should **only populate the text field**. The send button remains the single send trigger.

---

#### M-9 · Caregiver Hub Shows No Indicator of Whether Patient Is Being Monitored

**Screen:** Caregiver Hub  
**Heuristic Violated:** #1 — Visibility of System Status  
**Observation:** No persistent status shows whether Asha is actively monitoring the patient. Caregivers navigate to the Patient tab to check.  
**Fix:** Add a live status chip at top of hub: *"🟢 Asha monitoring patient"* / *"🔴 Monitoring paused"* reflecting `_monitorStatus`.

---

### 🟡 MINOR Issues

---

#### m-1 · Caregiver Hub Cards Use Inconsistent Border Treatments

**Screen:** Caregiver Hub  
**Heuristic Violated:** #4 — Consistency and Standards  
**UX Law Violated:** Gestalt — Similarity  
**Fix:** Standardize: teal border = primary action card, red border = emergency, no border = informational.

---

#### m-2 · Double-Title Header Is Redundant and Verbose

**Screen:** Caregiver Hub top header (`caregiver_page.dart` line 255)  
**Heuristic Violated:** #8 — Aesthetic and Minimalist Design  
**Observation:** All-caps "NEUROBRIDGE ASHA • CAREGIVER" stacked above "Caregiver Hub" heading — two title-like elements.  
**Fix:** Remove all-caps label. Use only "Caregiver Hub" as headlineMedium.

---

#### m-3 · Quick Signal Test Buttons Unreachable in Switch Scanning Mode

**Screen:** Patient Dashboard (`patient_page.dart` lines 789–814)  
**Heuristic Violated:** #7 — Flexibility and Efficiency of Use  
**Fix:** Wrap `_TestSignalButton` row in `ExcludeSemantics` or include in `SingleSwitchScanningView` grid.

---

#### m-4 · "LIVE WEBCAM CV" Badge Uses 10px Font — Below Accessible Minimum

**Screen:** Patient Dashboard camera feed (`patient_page.dart` line 621)  
**Heuristic Violated:** #4 — Consistency and Standards  
**Fix:** Increase to `fontSize: 12` or replace with a colored dot + simplified "LIVE" label.

---

#### m-5 · Role Card Subtitles Are Feature-Lists, Not User-Task Language

**Screen:** Role Selection (`role_selection_page.dart`)  
**Heuristic Violated:** #10 — Help and Documentation  
**Fix:** Rewrite subtitles in first-person, task-oriented language:  
- Patient: *"Asha listens to your eyes, face, and hands and speaks for you."*  
- Caregiver: *"Set up how the patient communicates and get alerts when they need help."*

---

#### m-6 · Dwell Time Slider Allows 0ms — Causes False Positive Triggers

**Screen:** Calibration Wizard Step 6  
**Heuristic Violated:** #5 — Error Prevention  
**Fix:** Set `min: 50` (not 0). Add warning when <100ms: *"May trigger accidentally for patients with tremors."*

---

#### m-7 · Caregiver Voice Setup Card Is Buried 6 Cards Deep

**Screen:** Caregiver Hub  
**Heuristic Violated:** #8 — Aesthetic and Minimalist Design  
**UX Law Violated:** Gestalt — Proximity  
**Fix:** Move Voice Setup directly below Patient Signal Calibration. Group under **"Calibration & Voice"** section header.

---

#### m-8 · "TensorFlow.js Model: …" Snackbar Exposes ML Framework Names to Users

**Screen:** Hand Calibration Page (`hand_calibration_page.dart` line 104)  
**Heuristic Violated:** #2 — Match Between System and Real World  
**Fix:** Replace prefix "TensorFlow.js Model:" with **"Asha Hand Model:"** or omit prefix entirely: *"✓ 3 gestures trained and ready."*

---

## Heuristic Coverage Summary

| Nielsen Heuristic | Issues Found |
|---|---|
| H1 · Visibility of System Status | C-5, M-6, M-7, M-9 |
| H2 · Match Between System and Real World | C-2, C-7, M-5, m-5, m-8 |
| H3 · User Control and Freedom | C-3, C-6, M-3 |
| H4 · Consistency and Standards | C-3, m-1, m-4 |
| H5 · Error Prevention | C-1, C-7, M-8, m-6 |
| H6 · Recognition vs. Recall | C-2, M-5, m-7 |
| H7 · Flexibility and Efficiency | C-6, M-4, m-3 |
| H8 · Aesthetic and Minimalist Design | C-4, M-2, m-2, m-7 |
| H9 · Help Diagnose and Recover from Errors | C-5, M-7 |
| H10 · Help and Documentation | C-1, m-5 |

---

## UX Law Coverage Summary

| UX Law | Issues Found |
|---|---|
| **Fitts's Law** | C-1 (SOS delay), C-6 (no large back button), M-4 (coaching countdown) |
| **Hick's Law** | C-3 (3-way launch dialog), C-4 (19 signals at once) |
| **Jakob's Law** | C-2 (Calibrate label), C-7 (UUID input), m-5 (role subtitles) |
| **Gestalt – Proximity** | m-7 (voice setup card placement) |
| **Gestalt – Similarity** | M-2 (emergency vs. normal buttons), m-1 (inconsistent card borders) |
| **Gestalt – Figure-Ground** | M-2 (critical actions not visually differentiated) |

---

## Recommended Fix Priority (Sprint Plan)

### Sprint 1 — Safety & Clinical Compliance (Weeks 1–2)
| Issue | Action |
|---|---|
| C-1 | Replace SOS confirmation dialog with press-and-hold + undo snackbar |
| C-5 | Add face framing guide overlay + recovery instructions |
| M-4 | Increase coaching countdown to 15s; make it configurable |
| M-8 | Remove preset chip auto-send behavior |

### Sprint 2 — Caregiver Experience (Weeks 3–4)
| Issue | Action |
|---|---|
| C-2 | Relabel "Calibrate" → "Train Hand Gestures" / "Manage Saved Gestures" |
| C-7 | Add QR scan + UUID format validation + helper text |
| C-4 | Collapse wizard signal list to 3 recommended + show-more |
| M-9 | Add patient monitoring status chip to Caregiver Hub header |
| m-7 | Reorder Caregiver Hub: move Voice Setup below Calibration |

### Sprint 3 — Patient Autonomy & Accessibility (Weeks 5–6)
| Issue | Action |
|---|---|
| C-3 | Convert first-launch modal to full onboarding screen |
| C-6 | Add large "Done" FAB in patientExecution mode |
| M-2 | Differentiate Emergency SOS button visually (size + animation) |
| M-3 | Add undo for "Clear Local" alert history |
| M-7 | Add 10s timeout + auto-retry for camera release |

### Sprint 4 — Polish & Consistency (Weeks 7–8)
| Issue | Action |
|---|---|
| M-5 | Add semantic labels to Sensitivity slider |
| M-6 | Add live character counter to display message field |
| m-1 | Standardize card border system |
| m-2 | Simplify Caregiver Hub header |
| m-4 | Increase LIVE badge font to 12px |
| m-5 | Rewrite role selection subtitles |
| m-6 | Raise minimum dwell to 50ms, add tremor warning |
| m-8 | Remove "TensorFlow.js" from user-facing snackbar |

---

## Accessibility Addendum

The following issues fall outside the primary heuristic framework but are critical for the NeuroBridge Asha user population:

1. **Screen Reader (TalkBack/VoiceOver):** No `Semantics` wrappers found on interactive coach cards in the Calibration Wizard. All interactive elements must have `semanticsLabel` properties.

2. **Dynamic Text Scaling:** Hard-coded `fontSize` values combined with fixed-height `SizedBox` containers (e.g., `height: 52`) will clip text at large scale factors. Replace with `ConstrainedBox(constraints: BoxConstraints(minHeight: 52))`.

3. **High Contrast Mode:** Grey-on-dark text combinations like `Color(0xFF8CA0A8)` on `Color(0xFF0F1720)` yield ~3.2:1 contrast ratio — below WCAG AA's 4.5:1 minimum for body text.

4. **Single-Switch Scanning Coverage:** Quick Signal Test buttons and preset caption chips are not included in the `SingleSwitchScanningView` grid, making them permanently unreachable for switch users.

---

*Audit based on source code analysis of the NeuroBridge Asha Flutter codebase. Visual pass at `https://mysunatislam.github.io/NeuroBridge-Asha/` recommended to verify rendering and interaction feel.*
