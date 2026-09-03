# FingerSpeak Asha mobile

Flutter patient/caregiver client for the FingerSpeak wheelchair system. The app is intentionally
mobile-first: large controls, a patient reassurance screen, a minimal caregiver screen, and Asha as
a corner avatar that opens into a full-height conversation sheet.

## Implemented boundaries

- Asha tries `POST /v1/asha/chat` first and speaks every reply. A bounded local support message keeps
  core controls usable when the backend cannot be reached. The OpenAI key remains server-only.
- The front camera runs through ML Kit entirely on the phone. It emits face-present, blink, wink,
  smile, head-turn, and normalized facial-contour movement signals. It does **not** upload frames,
  diagnose muscle function, or claim precise pupil-gaze tracking.
- A calibrated signal triggers local speech first, without waiting for Wi-Fi. If a Pi is paired, the
  confirmed text caption is then sent using `fingerspeak.device.v1`.
- With explicit per-recording consent, a caregiver can directly record one exact configured phrase;
  there is no voice cloning. The audio stays in private app storage, is labeled as saved playback,
  and is invalidated whenever its phrase snapshot does not match the active words.
- Asha greets the patient, speaks chat replies, and offers a gentle check-in every 30 minutes while
  the app process is active. Hourly water reminders use local Android notifications.
- Setup exposes the phone’s installed TTS voice names and speech rate without inferring gender.
- The minimal caregiver view shows Pi status, can call the configured patient number, and can send
  a text caption directly to the paired Pi display.
- Pi credentials use Android secure storage. Pairing codes and API keys are never accepted in URLs
  or source configuration.
- Only after pairing, the phone accepts strict `patient.intent` v1 envelopes for the configured Pi
  device. It requires a fresh aware detection timestamp, increasing per-socket sequence, unique UUID,
  allowed intent, and confidence in `[0,1]`; gaps are allowed, but replays are not. The payload must
  contain only `intent`, `confidence`, and `detected_at`, so Pi-supplied phrases, audio, frames, or
  landmarks can never become speech. Valid edge events resolve the phone’s local calibration and
  retain the normal two-second trigger cooldown.
- Edge-triggered emergency-risk wording is armed by one valid event and spoken only after a second
  distinct valid event arrives within ten seconds. Disconnecting clears that armed state.

This is an assistive prototype, not a medical device. Face/eye signals need patient-specific
validation, false-activation measurement, consent, and an accessible physical fallback before care
use.

## Required local tooling

Flutter is installed at `C:\Users\Kotha\Development\flutter`. The examples below use its full
path so they work in PowerShell even when Flutter is not on `PATH`. Android SDK/ADB are available
at `C:\Users\Kotha\AppData\Local\Android\Sdk`. A physical phone was not connected during the
latest automated validation.

On another workstation:

1. Add `C:\Users\Kotha\Development\flutter\bin` to `PATH`.
2. Install Android Studio with Android SDK Platform 35 or newer, SDK build tools, platform tools, and an
   emulator; accept licenses with `flutter doctor --android-licenses`.
3. A physical Android phone is recommended for camera, microphone, notification, and call testing.

The Android host project is checked in. This optional repair script recreates it only if it is
missing, then reapplies the FingerSpeak manifest, Gradle settings, and launcher class without
replacing Dart app source:

```powershell
Set-Location "C:\Users\Kotha\OneDrive\Documents\ChatGPT\Fingerspeak\apps\mobile"
.\tool\bootstrap_android.ps1
```

Run against the Docker backend from the Android emulator:

```powershell
flutter run `
  --dart-define=FINGERSPEAK_API_BASE_URL=http://10.0.2.2:8000/v1 `
  --dart-define=FINGERSPEAK_PI_WS_URL=ws://10.0.2.2:8765/v1/device/ws `
  --dart-define=FINGERSPEAK_CAREGIVER_PHONE=+8801000000000 `
  --dart-define=FINGERSPEAK_PATIENT_PHONE=+8801000000001
```

For a physical phone, replace `10.0.2.2` with the computer or Pi LAN address. The backend and Pi
must explicitly bind to a LAN interface, the firewall must permit only the required private-network
ports, and production builds must use authenticated `https://` and `wss://` endpoints. The checked-in
Android manifest permits cleartext traffic only to make local development possible; disable that
before distributing a production build.

The first time the phone connects directly to the edge service, enter its one-time pairing code on
the Setup tab. The rotated device credential is stored in secure storage and reused on later runs.

## Checks and GitHub artifacts

From `apps/mobile` in PowerShell:

```powershell
& 'C:\Users\Kotha\Development\flutter\bin\flutter.bat' analyze
& 'C:\Users\Kotha\Development\flutter\bin\flutter.bat' test
& 'C:\Users\Kotha\Development\flutter\bin\flutter.bat' build apk --release
```

`.github/workflows/ci.yml` repeats those checks and uploads a short-lived debug APK. The separate
`mobile-artifact.yml` workflow can be started manually or by a `mobile-v*` tag; it uploads split APKs
and SHA-256 checksums as workflow artifacts only. It does not publish to an app store, create a
GitHub Release, deploy a backend, or contain signing/API secrets. The evaluation APK uses debug
signing and placeholder secure endpoints; real distribution requires organization-owned Android
signing material in GitHub secrets and an approved release process.

The local release APK is written to `build/app/outputs/flutter-apk/app-release.apk`. This remains
an evaluation build, not an app-store release. The unchanged hand calibration page has a
pre-existing unused-import analyzer warning; it is intentionally outside the face-only changes.

iOS uses the same Dart source. Windows cannot run the Xcode build. The existing
`.github/workflows/ios_build.yml` runs on macOS and packages an **unsigned** IPA for sideloading;
it must build the updated source and be signed appropriately before device installation.

## Asha Guide and face calibration

Asha Guide is a deterministic, local walkthrough rather than a medical AI agent. It leads through
role selection, the patient ability profile, calibration, a first session, and session progress.
It supports voice replay, Back, Skip, persisted resume, and replay from Setup. The spotlight does
not block emergency controls. Completing an assessment or calibration advances the walkthrough;
canceling one does not falsely mark it complete.

Custom face calibration now requires distinct timestamped frames over a minimum capture period,
stable neutral measurements, and a successful test of the selected movement. Sensitivity previews
change the actual face detector thresholds; save, import, restart, and standard-profile reset all
refresh those live settings. Unknown eye/smile measurements are unavailable rather than replaced
with invented neutral values.

The former fixed `16 bpm` display was a placeholder for breathing, not heart rate. The replacement
is explicitly a **camera breathing estimate, not a medical measurement**. It uses periodic
face-box movement, needs a sustained quality window, and becomes unavailable after unsuitable
motion or tracking loss. It cannot distinguish every breathing movement from head/camera sway.
It must not be used for apnea detection, diagnosis, or clinical decisions. Experimental periocular
and lip micro-movement features describe contour motion, not measured iris tremor or muscle
activity; they require explicit calibration/mapping.

Android face frames are validated as packed NV21 or converted from Y/U/V planes using their real
row/pixel strides. iOS BGRA buffers retain their row stride. Unsupported/malformed layouts produce
an honest unavailable/error state. See the primary
[Android YUV format specification](https://developer.android.com/reference/android/graphics/ImageFormat#YUV_420_888)
and [ML Kit byte-array requirements](https://developers.google.com/ml-kit/vision/face-detection/android).
The MediaPipe hand runtime and model assets are not changed by this work.

Before a patient trial, check on each target phone:

1. Deny camera permission, retry after granting it, background/resume the app, and switch between
   face calibration and the hand communicator. Never accept a fake face-detected state.
2. Capture a relaxed baseline, then deliberately move during capture and confirm rejection.
3. Test each mapped movement separately, save it, restart the app, and repeat. Also record a long
   neutral interval and count false activations.
4. Confirm one deliberate movement produces one phrase and emergency controls remain reachable.
5. Replay Asha Guide for both Patient and Caregiver roles, cancel and complete setup routes, and
   test large text and reduced-motion settings.
6. Verify caregiver recording playback and speech on the physical device; unit tests cannot prove
   microphone, speaker, camera, or permission behavior.

The laptop-side [research benchmark](../../tools/research_benchmark/README.md) remains available
for the existing hand telemetry pipeline. Its results do not establish face recognition accuracy
or validate the experimental breathing estimate. Face validation needs separately labelled,
held-out patient/device trials and an independent reference for any physiological comparison.
