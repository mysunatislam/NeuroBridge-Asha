# FingerSpeak Android research benchmark

This laptop-side tool runs randomized, externally labelled gesture trials over
USB/ADB and writes analysis-ready files. It does not add a benchmark dashboard
to the patient app. A profile APK compiled with `FINGERSPEAK_RESEARCH=true`
emits a small hidden telemetry stream; ordinary builds do not emit it.

The hidden stream contains aggregate timing and gesture labels only. It does
not log hand landmarks, camera frames, audio, spoken phrases, patient names, or
the phone serial number.

## What is measured

| Result | Source | Interpretation |
| --- | --- | --- |
| Gesture accuracy, Wilson 95% CI, confusion matrix, macro F1 | Randomized laptop prompts plus confirmed app activations | External held-out task performance, including misses and wrong activations |
| Rest specificity / false activations | Randomized no-gesture windows | Safety-oriented negative-class performance |
| Host-observed latency | Enter key at gesture onset to research log receipt | End-to-end activation observation including human cueing, ADB, and logcat overhead |
| Device activation latency | First stable candidate to confirmed activation | On-device dwell/confirmation latency; not speech-audio onset |
| Classifier time | JavaScript timer around model classification | Model execution only; feature extraction and speech are separate |
| MediaPipe time and tracking FPS | Hidden WebView aggregates | Actual hand-landmark processing time and processed camera-frame rate |
| CPU and PSS/RSS memory | `adb shell top` and `dumpsys` | External periodic samples; the package aggregate and main process are kept separate |
| Android UI frame timing | `dumpsys gfxinfo ... framestats` | UI-rendering diagnostic, reported separately from MediaPipe tracking FPS |
| Thermal/battery/device metadata | ADB snapshots before and after | Context needed to explain throttling and device-to-device differences |

Android recommends measuring on a physical device, controlling environmental
variation, warming up the app, and storing individual results rather than only
an aggregate. See the official [performance-test guidance](https://developer.android.com/training/testing/instrumented-tests/performance),
[measurement overview](https://developer.android.com/topic/performance/measuring-performance),
and [`dumpsys` documentation](https://developer.android.com/tools/dumpsys).

## Requirements

- Windows laptop with PowerShell.
- Flutter SDK and Android SDK Platform-Tools. The wrapper auto-detects the
  standard locations used on this laptop. Override them with
  `FINGERSPEAK_FLUTTER`, `FINGERSPEAK_DART`, or `FINGERSPEAK_ADB` if needed.
- A physical Android phone with Developer options and USB debugging enabled.
- A data-capable USB cable. Unlock the phone and accept its RSA debugging
  prompt.

If Windows blocks the local script, enable scripts only for the current
PowerShell process:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

## First run in PowerShell

```powershell
Set-Location 'C:\Users\Kotha\OneDrive\Documents\ChatGPT\Fingerspeak'
.\tools\research_benchmark\run_benchmark.ps1 build-install
.\tools\research_benchmark\run_benchmark.ps1 doctor
```

`build-install` builds a Flutter **profile** APK with hidden research telemetry
and installs it with `adb install -r`. `doctor` must show one authorized
physical phone and the installed package `org.fingerspeak.mobile`.

## Collect baseline and calibrated runs

Use pseudonymous participant/session IDs; never enter a name, hospital ID, or
other protected information. Determine trial counts with a pre-specified power
analysis rather than treating the example count as sufficient.

1. Fix camera distance, phone mount, orientation, lighting, hand used, refresh
   rate, power state, and room conditions. Record those conditions separately.
2. Create/load the model representing the baseline condition. Open Patient
   Mode, select finger movement, and enter the MediaPipe hand communicator.
3. Run the baseline command. The collector waits for live model telemetry and a
   warm-up before presenting randomized trials.
4. Perform calibration using training sessions that are distinct from the
   evaluation trials. Save the model, return to Patient Mode, and load it.
5. Run the calibrated command under the same conditions. Reusing the seed keeps
   the randomized trial protocol reproducible.

```powershell
.\tools\research_benchmark\run_benchmark.ps1 collect --phase baseline --participant P001 --session V01 --gestures 'Yes,No,Water,Nurse' --repetitions 10 --rest-trials 10 --seed 4217 --output 'research_results\P001_V01_baseline'
.\tools\research_benchmark\run_benchmark.ps1 collect --phase calibrated --participant P001 --session V01 --gestures 'Yes,No,Water,Nurse' --repetitions 10 --rest-trials 10 --seed 4217 --output 'research_results\P001_V01_calibrated'
.\tools\research_benchmark\run_benchmark.ps1 compare --baseline 'research_results\P001_V01_baseline' --calibrated 'research_results\P001_V01_calibrated' --output 'research_results\P001_V01_comparison'
```

At each non-Rest prompt, the operator presses Enter at the instant the patient
begins moving. At a Rest prompt, press Enter and remain neutral for the whole
window. The first confirmed activation is scored; no activation is a miss for a
gesture and a true negative for Rest.

Comparison defaults to an unpaired Newcombe-Wilson interval for the change in
accuracy. Use `--paired` only when participant, visit, expected label, seed, and
trial protocol were deliberately matched. The report shows absolute
percentage-point change and relative improvement separately.

## Outputs

Each run is written incrementally so partial data survive Ctrl+C:

- `trial_protocol.json` — exact randomized order and seed.
- `trials.csv` — one labelled trial per row.
- `events.jsonl` — raw hidden research events and host receive times.
- `system_samples.csv` — timestamped CPU and memory samples.
- `metadata.json` — protocol, software/device context, thermal/battery state,
  and collection warnings.
- `raw/start` and `raw/end` — original `dumpsys` snapshots.
- `summary.json` and `report.md` — computed results.

Re-run analysis without reconnecting the phone:

```powershell
.\tools\research_benchmark\run_benchmark.ps1 analyze 'research_results\P001_V01_baseline'
```

The primary report keeps these latency families separate. Do not add them
together or relabel device candidate-to-confirmation time as audio-onset
latency. For spoken-output timing, use an independent acoustic loopback test.

## Recommended study controls

- Use held-out evaluation sessions and movements that were not calibration
  samples. The model's internal validation score is diagnostic, not the final
  study accuracy.
- Randomize or counterbalance baseline/calibrated order when the design permits;
  otherwise practice and fatigue are confounded with calibration.
- Test multiple participants and multiple sessions per participant. Account for
  participant clustering in the final inferential analysis.
- Report all classes, misses, Rest false activations, confusion matrices, and
  confidence intervals—not just overall accuracy.
- Let the phone reach a stable thermal state and keep charging/airplane-mode
  conditions identical. Record exclusions and failed trials before inspecting
  results.
- ADB sampling has overhead. Use the default moderate interval for resource
  runs. If supported by the current collector, `--no-system-sampling` creates a
  telemetry-only pass for cleaner latency/FPS testing.
- Do not publish a single phone session as “research-grade validation.” The
  harness makes measurement reproducible; ethics approval, consent, a powered
  protocol, representative participants, and independent replication remain
  study responsibilities.

## Perfetto trace (optional)

For a system-level trace, keep the communicator active and run:

```powershell
.\tools\research_benchmark\run_benchmark.ps1 trace --duration 20 --output 'research_results\fingerspeak.perfetto-trace'
```

Open the result in [Perfetto UI](https://ui.perfetto.dev/). Perfetto's official
[Android quickstart](https://perfetto.dev/docs/quickstart/android-tracing)
explains trace capture and analysis. A trace supplements the CSV measurements;
it does not supply ground-truth gesture labels.

## Self-tests

```powershell
& 'C:\Users\Kotha\Development\flutter\bin\cache\dart-sdk\bin\dart.exe' --enable-asserts .\tools\research_benchmark\test\run_tests.dart
node --test .\apps\mobile\test\hand_studio_runtime_test.js
```

Use a production-like/profile build for performance work. Android's
[Macrobenchmark documentation](https://developer.android.com/topic/performance/benchmarking/macrobenchmark-overview)
is the appropriate next step for fully automated startup/navigation and repeatable
UI journeys; this harness focuses on patient-labelled gesture trials and model
pipeline telemetry.
