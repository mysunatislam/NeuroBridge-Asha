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

This workstation was audited on 22 August 2026. Flutter 3.47.1, Dart 3.13.1, and Java 17 are
available. Flutter is installed at `C:\Users\Kotha\Development\flutter`, but its `bin` directory is
not yet on `PATH`. The Android SDK/ADB are not installed, and no system software was installed
automatically.

Install:

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

After installing Flutter:

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-fatal-infos
flutter test
flutter build apk --debug
```

`.github/workflows/ci.yml` repeats those checks and uploads a short-lived debug APK. The separate
`mobile-artifact.yml` workflow can be started manually or by a `mobile-v*` tag; it uploads split APKs
and SHA-256 checksums as workflow artifacts only. It does not publish to an app store, create a
GitHub Release, deploy a backend, or contain signing/API secrets. The evaluation APK uses debug
signing and placeholder secure endpoints; real distribution requires organization-owned Android
signing material in GitHub secrets and an approved release process.

Local `flutter pub get` completed, `flutter analyze` reported no issues, and all ten Dart/Flutter
tests passed with Flutter 3.47.1. An APK build was attempted and stopped before Gradle because no
Android SDK is installed. Native plugin compilation and physical-device camera, microphone,
notification, calling, and ML Kit behavior therefore remain to be verified. GitHub Actions provides
the clean Android build and artifact check once these changes are pushed.
