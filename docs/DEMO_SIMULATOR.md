# Edge simulator demo

The simulator exercises pairing, telemetry, caption priority, reconnect credentials, and protocol
security without Raspberry Pi hardware or an AI key.

## Start

Install the package in a Python 3.11+ environment:

```powershell
python -m pip install -e "services/edge[dev]"
python -m fingerspeak_edge --adapter simulated
```

When no code is configured, the CLI prints a random one-time pairing code and listens only on
`127.0.0.1:8765`. The WebSocket URL is `ws://127.0.0.1:8765/v1/device/ws`; clients must offer
`fingerspeak.device.v1` and send `pairing.authenticate` first.

For a second device on a controlled LAN, set a high-entropy code through the environment and bind
explicitly:

```powershell
$env:FINGERSPEAK_EDGE_PAIRING_CODE = "replace-with-at-least-24-random-characters"
python -m fingerspeak_edge --adapter simulated --host 0.0.0.0
```

The simulated camera reports `ready`, tracking reports `tracking`, and both battery fields report
`null`. Captions are logged and retained in the in-memory display history for tests. The simulator
does not claim to run a real LLM, detect a person, read a wheelchair battery, or contact a caregiver.

## Tests

```powershell
python -m pytest -q --basetemp .tmp\pytest-edge services\edge\tests
python -m ruff check services\edge
```

Coverage includes strict/discriminated messages, Bangla text, unsafe/oversized text, forbidden motor
and shell commands, one-time-code rotation, device-credential reconnect, null batteries, stale/wrong
device messages, idempotency, emergency priority, no telemetry before authentication, origin and
subprotocol boundaries, binary frames, size limits, and lazy Picamera2 import failure.

Hardware checks belong in separately marked tests executed on a Pi. They must not make the ordinary
CI suite depend on a camera, display, GPIO, wheelchair, or Picamera2 installation.
