# FingerSpeak

FingerSpeak is a local-first assistive communication prototype for a wheelchair-mounted Raspberry
Pi, a patient phone, and a caregiver client. The primary React/Vinext application keeps gesture
recognition, captions, local speech, and explicit safety confirmation available without depending
on Asha or the cloud. When connectivity is available, the phone can use the Asha text companion,
authorized caregiver alerts, and optional cloud device status.

> FingerSpeak is not a validated medical device or emergency service. Do not use this prototype as
> a person's only communication, monitoring, or emergency pathway. It has no wheelchair propulsion
> or motor-control interface.

## System shape

```text
Raspberry Pi NoIR camera ─> Pi edge bridge ─> Raspberry Pi caption display
                                  ^
                                  | authenticated local WebSocket
                                  v
                        patient React/Vinext app
                           |               |
                 phone voice/calls        | HTTPS
                                           v
                              FastAPI control plane
                                  |               |
                         Asha LLM/RAG       caregiver client
```

The phone is the conversational surface: Asha replies, optional press-to-talk input, local speech
playback, and phone calls stay there. The Pi display is deliberately simpler and shows large
captions plus camera, tracking, phone-link, and power telemetry. Battery values remain `Unknown`
until a real Pi power monitor or wheelchair/BMS integration reports them.

## Phone application

`apps/web` is an installable mobile PWA, so the same tested patient and caregiver application can
run in a phone browser or from the home screen. Its phone layout puts Asha and the primary call,
display, and confirmed-help actions first, uses safe-area-aware bottom navigation, and keeps camera
and setup controls secondary. Asha's optimized portrait is precached with the offline shell.

The direct phone-to-Pi WebSocket waits for a matching `command.ack` before reporting a display
message as delivered. Confirmed help uses `emergency.display`, which receives priority over routine
captions on the Pi. Flutter is intentionally deferred until native-only needs justify a second
client—particularly protected credential storage, background reconnect, local-network discovery,
and production alternatives to an HTTPS page opening a plain local `ws://` connection.

## What is included

- **Primary React/Vinext PWA (`apps/web`):** patient, Pi Display, caregiver, and calibration views;
  bundled MediaPipe hand recognition; personalized nearest-prototype classification;
  out-of-distribution rejection; `REST → CANDIDATE → WAIT_RELEASE`; local SpeechSynthesis; optional,
  user-initiated browser speech recognition with a typed fallback; IndexedDB; PWA caching; explicit
  emergency confirmation; and honest offline/demo device states.
- **Asha companion boundary:** `POST /v1/asha/chat` accepts bounded text and optional patient-owned
  context. The API can use a server-only OpenAI Responses adapter and owner-scoped file search, or
  return a deterministic offline companion response when no provider is configured. No API key is
  stored in browser or Raspberry Pi code.
- **Raspberry Pi edge service (`services/edge`):** hardware-free simulator, Picamera2 camera
  lifecycle adapter, caption/emergency display state, telemetry, strict bounded messages,
  one-time-code pairing, heartbeat presence, and idempotent commands. It exposes no shell, media
  upload, cloud-AI, or wheelchair-control capability.
- **FastAPI control plane (`services/api`):** PostgreSQL/Alembic, ownership and caregiver grants,
  consent enforcement, session/event metadata, model registry, durable caregiver alerts,
  authenticated WebSocket replay, Asha chat, and optional scoped cloud device connections.
- **Python ML package (`services/ml`):** browser-parity 20×63 → 20×98 features, augmentation,
  session-aware evaluation, DTW and prototype baselines, optional TensorFlow export, and checksummed
  model bundles with safety metadata.
- **Legacy/reference surfaces:** `apps/web-vue` and `legacy/` are retained for provenance and
  comparison; neither is the primary application or Compose web service.

## Connectivity

For the wheelchair prototype, connect the Pi to the patient's phone hotspot and pair at runtime.
The direct local protocol keeps pairing credentials out of query strings and does not expose camera
frames. USB tethering can use the same IP/WebSocket protocol as a cable fallback. Production local
networking requires `wss://` or an equivalent native-wrapper security design; plain `ws://` is only
for a controlled prototype network.

The separate cloud device channel uses owner-created scoped credentials so authorized caregivers
can see durable status and captions when the Pi has internet access. A cloud socket by itself does
not prove the patient or local Pi is online.

## Fastest start

From the repository root in PowerShell:

```powershell
Copy-Item .env.example .env
.\scripts\dev.ps1
```

Then open `http://localhost:3000`. Development API documentation is at
`http://localhost:8000/docs`. With `OPENAI_API_KEY` blank, Asha uses the safe offline response;
local communication and the Pi demo preview remain available.

For non-container frontend development:

```powershell
.\scripts\bootstrap.ps1
Set-Location .\apps\web
npm.cmd run dev
```

PostgreSQL is required for the full API, but the browser's local communication path works when the
API is unavailable. Direct development may use the configured `local-user` identity. Staging and
production must set a 32-byte-or-longer `FINGERSPEAK_GATEWAY_HMAC_SECRET` and use a trusted gateway
that strips client `X-Actor-*` headers before injecting signed identity assertions. Browsers never
receive that shared secret.

## Raspberry Pi simulator

After bootstrapping, run the edge service without Raspberry Pi hardware:

```powershell
$env:FINGERSPEAK_EDGE_PAIRING_CODE = "replace-with-at-least-24-random-characters"
.\.venv\Scripts\python.exe -m fingerspeak_edge --adapter simulated
```

The service defaults to loopback. Binding to `0.0.0.0` exposes it to the LAN and must be an explicit
choice with a strong one-time code and trusted network. On Raspberry Pi OS, install Picamera2 from
the operating system and follow [docs/RASPBERRY_PI_SETUP.md](docs/RASPBERRY_PI_SETUP.md).

## Checks

```powershell
.\scripts\test.ps1
```

The script validates the React/Vinext frontend and rendered worker, API, ML package, Raspberry Pi
edge simulator/protocol, Python lint/compilation, and Compose configuration when Docker is present.

## Key directories

```text
apps/web          Primary React/Vinext patient, Pi Display, caregiver, and setup PWA
apps/web-vue      Legacy Vue presentation retained as a reference
services/api      FastAPI/PostgreSQL control plane, Asha, alerts, cloud device channel
services/edge     Authenticated Raspberry Pi bridge, adapters, simulator, and tests
services/ml       Training, evaluation, and model export package
contracts         Bounded browser, model, and device protocol schemas
docs              Architecture, device protocol, hardware, privacy, and safety notes
infra             Docker Compose development stack
scripts           Windows bootstrap, development, and verification workflows
legacy            Supplied archive provenance and original static prototype
```

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
[docs/PRIVACY_AND_SAFETY.md](docs/PRIVACY_AND_SAFETY.md), and
[docs/DEVICE_PROTOCOL.md](docs/DEVICE_PROTOCOL.md) before extending a trust boundary.
