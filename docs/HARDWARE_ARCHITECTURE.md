# FingerSpeak wheelchair hardware architecture

FingerSpeak separates the safety-sensitive wheelchair edge from conversation and cloud services.
The Raspberry Pi never receives an LLM API key and this project defines no wheelchair propulsion or
motor-control interface.

```text
NoIR camera -> Raspberry Pi edge service -> Raspberry Pi caption display
                         ^
                         | authenticated local WebSocket
                         v
                 patient phone application
                         |
                         | HTTPS / cloud realtime channel
                         v
              Asha LLM/RAG + caregiver service

 Raspberry Pi edge service -. optional outbound device WebSocket .-> caregiver cloud service
```

## Responsibilities

The Pi owns camera capture, tracking, the local caption display, and honest device telemetry. The
phone owns Asha conversation, phone speech input/output, explicit call handoff, cloud access, and the
direct Pi connection. The caregiver client reads authorized cloud state; a caregiver-to-cloud socket
does not prove that the patient or Pi is online.

Camera frames are not part of the device WebSocket contract and must not be uploaded by this edge
service. `pi_battery_percent` and `wheelchair_battery_percent` remain `null` until dedicated,
validated sensors exist. A Raspberry Pi cannot infer either percentage on its own.

## Optional cloud device relay

The edge service can also open the backend's existing `/v1/devices/{id}/ws` connection directly
over the phone hotspot. This relay is disabled unless all three cloud settings are present: the
server-provisioned device WebSocket URL, its scoped `fsd_` bearer token, and an Origin explicitly
allowed by the API. Unlike a browser WebSocket, the Python client can place the bearer token in the
`Authorization` header; it is never placed in a URL or logged.

The optional path publishes bounded, strictly increasing telemetry and receives durable caregiver
captions. Pi and wheelchair battery fields stay separate and independently nullable. Caption IDs
are applied idempotently, an unexpired local emergency display retains priority, and the Pi sends
`caption.ack` only after a caption is applied or recognized as an exact duplicate. Reconnection uses
bounded exponential backoff and recovers its telemetry sequence floor from cloud status.

This relay carries JSON status and captions only. Camera frames, landmarks, audio, shell commands,
and wheelchair motor commands have no relay message type. The direct phone-to-Pi socket remains the
patient interaction path; enabling cloud relay does not turn the cloud into the camera or drive
controller.

## Connectivity

Use the patient's Wi-Fi hotspot first. Pair the phone to the Pi at a runtime-discovered IP rather
than compiling an IP into the app. Android USB tethering is the preferred cable fallback because it
keeps the same IP/WebSocket protocol. Bluetooth may assist discovery, but is not the main transport.

The development server defaults to loopback. Binding to `0.0.0.0` exposes it to the local network
and therefore requires a strong one-time pairing code, exact allowed origins where feasible, and a
trusted hotspot. Plain `ws://` is for a controlled prototype only; production should use `wss://`
and a native mobile wrapper or another platform-supported local-network security design.

## Safety boundary

- `caption.set` renders plain patient-facing text.
- `emergency.display` has visual priority but does not call emergency services.
- No message can execute a shell command or control wheelchair motors.
- The cloud device token is scoped, owner-provisioned, revocable, and stored only on the Pi.
- WebSocket delivery is not a sole emergency or AAC pathway.
- NoIR-based face/wellbeing inference remains disabled until validated with the installed camera,
  lighting, mount, and target users.
- Wheelchair power integration requires an appropriate fused and isolated DC-DC design, safe
  shutdown behavior, strain relief, and review by a qualified hardware professional.

Resolve the exact Pi board, NoIR camera SKU, display SKU, ribbon cables, enclosure, and power system
before producing a final bill of materials. Connector requirements differ between Pi generations.
