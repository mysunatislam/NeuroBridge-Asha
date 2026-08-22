# FingerSpeak edge service

This package runs beside the Raspberry Pi camera and display. It exposes one bounded,
pairing-token-authenticated WebSocket for the patient phone and has no wheelchair motor-control,
shell-command, media-upload, or cloud-AI capability.

The default simulator has no Raspberry Pi dependencies:

```powershell
python -m fingerspeak_edge --adapter simulated
```

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

See `../../docs/DEVICE_PROTOCOL.md` and `../../docs/RASPBERRY_PI_SETUP.md` before exposing the
service beyond loopback.
