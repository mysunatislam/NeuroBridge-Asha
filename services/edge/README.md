# FingerSpeak edge service

This package runs beside the Raspberry Pi camera and display. It exposes one bounded,
pairing-token-authenticated WebSocket for the patient phone and has no wheelchair motor-control,
shell-command, media-upload, or cloud-AI capability.

The default simulator has no Raspberry Pi dependencies:

```powershell
python -m fingerspeak_edge --adapter simulated
```

## Local patient-intent monitoring

The edge service has a calibrated, one-shot face/eye intent pipeline and authenticated broadcast
path. A detector returns only normalized movement scores to the monitor; the WebSocket emits only a
strict `patient.intent` semantic event. Camera frames, crops, landmarks, calibration samples,
identity, emotion, pain, and medical inferences are never protocol fields.

The deterministic detector is intentionally opt-in and is suitable only for tests or a visible
demo. This example calibrates on neutral samples and emits one `blink` event:

```bash
python -m fingerspeak_edge \
  --adapter simulated \
  --intent-detector simulated \
  --simulate-intent blink
```

`--intent-detector off` is the default. The bundled Picamera2 adapter starts and locally captures
the NoIR camera, but a production MediaPipe/OpenCV score adapter is **not bundled yet** because the
required native wheels and delegate combinations have not been verified across supported
Raspberry Pi Model B generations. Do not claim real face/eye recognition or enable the simulated
detector on a deployed wheelchair. A real adapter must implement `FaceIntentDetector`, keep raw
frames inside that adapter, and pass Raspberry Pi hardware validation before selection is added to
the CLI.

Available semantic IDs are `blink`, `look_left`, `look_right`, `eyebrows_up`, and `mouth_open`.
Neutral calibration, debounce, mapped default safety dwell, cooldown, and release-before-rearm all
run on the Pi. `mouth_open` retains a total 1.5-second dwell because it is the default emergency
mapping; the phone additionally confirms emergency remappings because bindings are phone-local.

For a LAN demo, bind explicitly and set a stable, high-entropy token through the environment:

```powershell
$env:FINGERSPEAK_EDGE_PAIRING_CODE = "replace-with-at-least-24-random-characters"
python -m fingerspeak_edge --adapter simulated --host 0.0.0.0
```

On Raspberry Pi OS, install Picamera2 using the operating-system package, then choose the adapter:

```bash
sudo apt install -y python3-picamera2
python -m fingerspeak_edge --adapter picamera2 --host 0.0.0.0
```

## Persist pairing across restarts

Persistence is opt-in. Set an absolute, service-account-only path before the first pairing:

```bash
export FINGERSPEAK_EDGE_CREDENTIAL_STORE=/var/lib/fingerspeak/device-credential.json
export FINGERSPEAK_EDGE_PAIRING_CODE='replace-with-at-least-24-random-characters'
python -m fingerspeak_edge --adapter picamera2 --host 0.0.0.0
```

After the code is used once, the file contains only the device ID and a SHA-256 digest of the
rotated phone credential—never the credential itself. It is written through an atomic replacement.
On POSIX, newly created directories use mode `0700`, files use `0600`, and unsafe file ownership or
permissions are rejected. On Windows, put the file in a directory whose ACL grants access only to
the edge-service account.

A valid persisted digest is loaded on restart and keeps the pairing code consumed, even if the old
code remains in configuration. To deliberately pair a replacement phone, stop the service and run
the following as the same operating-system account that owns the store:

```bash
python -m fingerspeak_edge \
  --credential-store /var/lib/fingerspeak/device-credential.json \
  --reset-pairing
```

The reset command removes the digest and exits; it does not open a network reset endpoint. Configure
a fresh one-time pairing code before starting the service again. Keep the store out of shared folders,
source control, and backups that are readable by other accounts.

See `../../docs/DEVICE_PROTOCOL.md` and `../../docs/RASPBERRY_PI_SETUP.md` before exposing the
service beyond loopback.
