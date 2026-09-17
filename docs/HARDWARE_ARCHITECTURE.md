# NeuroBridge Asha Wheelchair Hardware Architecture

NeuroBridge Asha separates the safety-critical wheelchair edge from conversational and cloud services. The on-wheelchair edge hardware provides zero-latency offline perception, continuous patient wellbeing monitoring, and high-visibility caption display.

```text
                                  ┌───────────────────────────┐
                                  │      PATIENT ON WHEELCHAIR│
                                  └─────────────┬─────────────┘
                                                │
                                    ┌───────────┴───────────┐
                                    ▼                       ▼
                           NoIR Camera Module v3     Directional Mic
                                    │                       │
                                    └───────────┬───────────┘
                                                │
                                                ▼
 ┌─────────────────────────────────────────────────────────────────────────────────────────────┐
 │                         WHEELCHAIR EDGE PROCESSING UNIT                                     │
 │                                                                                             │
 │   Raspberry Pi 5 (8GB) + Google Coral Edge TPU USB Accelerator                              │
 │   • Hardware-accelerated MediaPipe landmark extraction                                      │
 │   • Dual-hand 21-point micro-gesture tracking                                               │
 │   • 478-point facial mesh (EAR blink, MAR mouth, PAINAD grimace)                            │
 │   • 2.5s temporal filter & tremor/spasm veto                                                │
 │   • Local deterministic offline intent classifier                                           │
 └──────────────────────────────┬───────────────────────────────┬──────────────────────────────┘
                                │                               │
                     Local HDMI / MIPI-DSI             Local 5W Amplified
                                │                           Speaker
                                ▼                               │
                   ┌─────────────────────────┐                  ▼
                   │ 7" Sunlight-Readable    │        Neural Speech Playback
                   │ High-Contrast LCD       │        (Local Text-to-Speech)
                   │ • Large captions        │
                   │ • Proactive prompts     │
                   │ • Emergency alert cards │
                   └─────────────────────────┘
                                │
               Authenticated Local WSS / USB Tether
                                │
                                ▼
                   ┌─────────────────────────┐
                   │  Patient Mobile Device  │
                   │  (Android / iOS App)    │
                   └────────────┬────────────┘
                                │  Optional Cloud Relay (HTTPS/WSS)
                                ▼
                   ┌─────────────────────────┐
                   │  FastAPI Control Plane  │
                   │  & Caregiver Portal     │
                   └─────────────────────────┘
```

---

## 1. Hardware Component Bill of Materials (BOM)

| Component | Specification | Function |
|:---|:---|:---|
| **Compute Core** | Raspberry Pi 5 (8GB RAM, Quad-core Arm Cortex-A76 @ 2.4GHz) | On-device edge computer vision, local RAG retrieval, and device state machine. |
| **Edge AI Accelerator** | Google Coral USB Accelerator (Edge TPU, 4 TOPS @ 0.5W/TOPS) | High-speed TFLite inference of 478-point Face Mesh and Hand Kinematic models. |
| **Optical Sensor** | Raspberry Pi Camera Module 3 NoIR (12MP Sony IMX708, Night-capable) | Captures patient gestures and facial expressions across ambient daylight and night conditions without visible glare. |
| **Display Unit** | 7-inch Sunlight-Readable IPS Display (1024×600, 800 nits, HDMI/DSI) | Mounts to wheelchair tray or side rail; presents large, high-legibility communication captions to interlocutors. |
| **Audio Transducers** | ReSpeaker USB 2-Mic Array + 5W Encapsulated Mini-Speaker | Noise-canceling directional speech intake + audible, empathetic companion voice playback. |
| **Power Management** | Galvanically Isolated 24V/12V to 5V 5A Buck Converter + LiFePO4 UPS | Safely draws from wheelchair battery system with surge isolation and clean shutdown signaling. |
| **Mounting Hardware** | Modular Articulating Arm with Ball-Head Camera Mount | Clamps securely to wheelchair frame; allows ergonomic alignment to patient lap and face. |

---

## 2. Offline Operational Architecture

In hospital ICUs, rural communities, transit vehicles, or network outages, the wheelchair system operates in **Full Autonomous Offline Mode**:
1. **Zero Cloud Requirement:** The camera feed is processed directly on the Pi/Coral TPU via MediaPipe. No frames leave the local memory bus.
2. **Deterministic & Local Model Intent:** Gesture sequences and blink patterns are evaluated against the patient's calibrated `patient_profile.json`.
3. **Instant Display & Audio:** When an intent is confirmed (e.g., *"Water"*, *"Pain in shoulder"*, *"Help"*), the Pi immediately displays the text on the 7" screen and vocalizes it through the speaker.
4. **Local Event Logging:** Telemetry and symptom observations are stored in encrypted local SQLite/JSON logs and synchronize automatically when network connectivity is restored.

---

## 3. Safety Boundary & Medical Isolation

* **No Motor Control:** NeuroBridge Asha has no physical wiring or CAN-bus transmission to wheelchair drive motors or steering throttles. It is strictly an assistive communication and monitoring instrument.
* **Isolated Power:** The power interface employs dual optocouplers and reverse-polarity protection to prevent interference with wheelchair motor drives.
* **Privacy Assurance:** Video streams and audio recordings remain on edge memory; only structured metadata (event timestamps, intent codes, verified alert levels) is transmitted over authorized cloud channels.
