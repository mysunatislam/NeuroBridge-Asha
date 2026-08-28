# FingerSpeak Research Benchmark — Second Laptop Setup Guide

This package contains everything needed to collect real performance data from the FingerSpeak Android application on your connected Android phone.

---

## 1. Prerequisites on the Second Laptop

1. **Flutter SDK**: Installed and in PATH (or accessible).
2. **Android SDK Platform-Tools (ADB)**: Installed (with `adb.exe`).
3. **Android Phone**: 
   - Developer Options enabled.
   - USB Debugging enabled.
   - Connected via USB data cable (accept RSA fingerprint prompt on phone).

---

## 2. Quick Verification (Doctor Check)

Open PowerShell in this unzipped directory:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\tools\research_benchmark\run_benchmark.ps1 doctor
```

*(Confirms ADB finds your phone and verifies communication).*

---

## 3. Build & Install the Research Profile APK

```powershell
.\tools\research_benchmark\run_benchmark.ps1 build-install
```

*(Builds the Flutter profile APK with hidden research telemetry and installs it via ADB).*

---

## 4. Run Baseline vs Calibrated Data Collection

### Step 4A: Baseline Collection (Pre-Calibration)
1. Open the app on the phone -> enter **Patient Mode** -> **Hand Studio**.
2. Run in PowerShell:
```powershell
.\tools\research_benchmark\run_benchmark.ps1 collect `
  --phase baseline `
  --participant P001 `
  --session V01 `
  --gestures "Yes,No,Water,Nurse" `
  --repetitions 10 `
  --rest-trials 10 `
  --seed 4217 `
  --output "research_results\P001_V01_baseline"
```
3. At each prompt, press Enter on the laptop when the gesture begins.

### Step 4B: Calibrate Custom Gestures
1. On the phone, record 8 reps per gesture in the Calibration tab and tap **Train**.
2. Switch back to **Patient Mode / Speak Mode**.

### Step 4C: Calibrated Collection (Post-Calibration)
```powershell
.\tools\research_benchmark\run_benchmark.ps1 collect `
  --phase calibrated `
  --participant P001 `
  --session V01 `
  --gestures "Yes,No,Water,Nurse" `
  --repetitions 10 `
  --rest-trials 10 `
  --seed 4217 `
  --output "research_results\P001_V01_calibrated"
```

---

## 5. Generate Statistical Comparison Report

```powershell
.\tools\research_benchmark\run_benchmark.ps1 compare `
  --baseline "research_results\P001_V01_baseline" `
  --calibrated "research_results\P001_V01_calibrated" `
  --output "research_results\P001_V01_comparison"
```

### Outputs Generated:
- `report.md`: Markdown summary table with accuracy (%), Wilson 95% CI, response latency percentiles (ms), FPS, and CPU/RAM usage.
- `summary.json`: Complete structured JSON.
- `trials.csv`: Trial-by-trial ground truth vs predicted activations.
- `system_samples.csv`: Real-time CPU % and PSS/RSS RAM measurements.
