# Raspberry Pi edge setup

Confirm the precise Model B generation, NoIR camera, and display before wiring. Raspberry Pi 5 uses
different camera/display ribbon connectors from several earlier boards. Mount electronics in an
enclosure, protect cables from wheelchair movement, and disconnect power before changing ribbons.

Use a current Raspberry Pi OS image. The supported camera stack is `rpicam-*`/libcamera with
Picamera2; do not build against legacy `raspistill`, `raspivid`, or the original Picamera library.

## Camera smoke check

```bash
sudo apt update
sudo apt install -y python3-picamera2
rpicam-hello --timeout 5000
```

The Pi adapter imports Picamera2 only when selected. Install the ordinary Python package in a
virtual environment while retaining access to the OS Picamera2 package, for example by creating the
environment with `--system-site-packages`:

```bash
python3 -m venv --system-site-packages .venv
.venv/bin/python -m pip install -e "services/edge[dev]"
```

## Run on loopback first

```bash
export FINGERSPEAK_EDGE_PAIRING_CODE='replace-with-at-least-24-random-characters'
export FINGERSPEAK_EDGE_CREDENTIAL_STORE='/var/lib/fingerspeak/device-credential.json'
.venv/bin/python -m fingerspeak_edge --adapter picamera2
```

The absolute credential-store path is optional for a disposable simulator but required for a
restarting wheelchair unit. It stores only the SHA-256 digest of the rotated credential and keeps
the one-time code consumed across restarts. Run the service as a restricted account; its parent
directory must not be group/world writable and the file must remain owner-only. To deliberately
replace the paired phone, stop the service, run `python -m fingerspeak_edge --reset-pairing` with
the same credential-store environment, provision a fresh pairing code, and restart.

After verifying `/health/ready`, bind to the phone hotspot interface and restrict the expected app
origin when the platform supplies one:

```bash
.venv/bin/python -m fingerspeak_edge \
  --adapter picamera2 \
  --host 0.0.0.0 \
  --allowed-origin https://patient.example
```

Do not put the pairing code on a command line in a deployed unit; command lines may be visible to
other processes. Provision it through a protected environment file or service credential.

## Optional caregiver-cloud relay

First register the Pi through the authenticated owner API. The registration response shows its
scoped `fsd_` device token once. Store that token in a root-owned `0600` environment file or, for a
hardened `systemd` unit, a service credential. Never put it in source control, a URL, a command-line
argument, browser storage, or logs.

Set all three values to enable the relay:

```bash
export FINGERSPEAK_EDGE_CLOUD_DEVICE_WS_URL='wss://api.example/v1/devices/DEVICE_UUID/ws'
export FINGERSPEAK_EDGE_CLOUD_ORIGIN='https://patient.example'
export FINGERSPEAK_EDGE_CLOUD_DEVICE_TOKEN='fsd_SERVER_PROVISIONED_SECRET'

.venv/bin/python -m fingerspeak_edge \
  --adapter picamera2 \
  --host 0.0.0.0 \
  --cloud-transport wifi
```

The Origin must exactly match an entry allowed by the cloud API. Use `--cloud-transport usb` after
switching to phone USB tethering, or `ethernet` when appropriate. If the cloud URL, Origin, and token
are all absent, the relay is disabled and the Pi remains local-only. Partial cloud configuration is
rejected at startup.

The relay sends only bounded JSON telemetry: monotonic sequence, observation time, camera/display
state, transport, `pi_battery_percent`, and `wheelchair_battery_percent`. Both percentages remain
`null` unless their respective sensor exists. It receives short cloud captions, renders an exact
caption once, and returns `caption.ack`; it never sends camera frames, audio, or motor commands.

For a local development API, `ws://` can be used on a trusted test network. A deployed relay should
use `wss://`, a valid server certificate, and a revocable token. Revoke and reprovision the device
from the owner account if the token may have been exposed.

## Network fallback

For Wi-Fi, connect the Pi to the patient's WPA2/WPA3 phone hotspot and pair using the assigned local
IP. If Wi-Fi is unreliable, enable phone USB tethering and reconnect to the Pi's USB-network IP; the
WebSocket messages do not change. Test the exact phone, cable, carrier policy, and reconnect behavior.

## Deployment work still required

Before unattended wheelchair use, add a restricted system user, a hardened `systemd` unit, protected
service-credential provisioning, log rotation, read-only or resilient storage where appropriate,
watchdog/restart policy, clean shutdown, thermal monitoring, and TLS. The included display adapter
is a simulator/log sink; a physical kiosk/framebuffer adapter must render text only and report real
display connectivity.

Never power the Pi directly from an unspecified wheelchair rail. Select a fused, isolated,
appropriately rated converter after the exact Pi/display/camera power budget is known.
