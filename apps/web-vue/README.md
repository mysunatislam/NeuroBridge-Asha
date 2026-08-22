# FingerSpeak Vue frontend

This is the primary Vue 3 presentation layer for FingerSpeak. It keeps the safety-critical recognition path local while separating UI, device inference, application state, and optional network synchronization.

## Why Vue here

- Vue 3 Single-File Components with `<script setup lang="ts">` keep accessible UI and behavior colocated without putting ML logic inside components.
- Composition API composables isolate camera/MediaPipe lifecycle, speech output, and caregiver WebSocket behavior.
- Pinia owns durable application state: profile, active edge model, cloud status, remote link, session quality, and recent spoken events.
- Vue Router lazy-loads the purpose selector, five dedicated support modes, Speak, Calibrate, and Caregiver workspaces so each workflow has a clear boundary.
- The existing TypeScript feature extraction, OOD rejection, intent state machine, IndexedDB storage, API client, and model bundle verifier are reused unchanged where possible.

## Architecture

```text
Vue SFC views
   │
   ├─ Pinia store ────────────── IndexedDB / optional FastAPI sync
   │
   ├─ useCameraInference()
   │      ├─ MediaPipe HandLandmarker (two hands, local WASM)
   │      ├─ optional FaceLandmarker (head/eye/expression observation)
   │      ├─ 20×63 raw sequence → 20×98 engineered features
   │      ├─ personalized nearest-prototype + OOD gate
   │      └─ REST → CANDIDATE → WAIT_RELEASE safety machine
   │
   ├─ useCommunication() ────── local SpeechSynthesis + touch fallback
   │
   └─ useCaregiverRealtime() ─ authorized WebSocket + durable replay
```

## Run

```bash
npm install
npm run dev
```

The Vue dev server runs on `http://localhost:3000`. Set `VITE_API_URL` if the FastAPI control plane is not at `http://localhost:8000/v1`.

## Checks

```bash
npm run typecheck
npm run test
npm run build
```

The copied core tests exercise the feature pipeline, OOD behavior, intent machine, and model-bundle validation. This remains a prototype and is not a validated medical device or emergency service.


## Asha AI assist upgrade

Asha is the floating bottom-right copilot. Version 2.4 adds purpose-based mode pages, bright/dark glow themes, selectable female/male English/Bangla browser speech, proactive voice prompts, two-hand observation, optional face/head/eye wellbeing cues, calibration guidance, contextual phrase suggestions, a voice-only movement routine, hydration nudges, and an optional trusted-contact `tel:` handoff for mobile browsers.

Wellbeing cues are assistive prompts only; they are not medical, emotion, or pain diagnoses. Calls always require an explicit user confirmation.


See `ASHA_2.4_FEATURES.md` for the multimodal vision behavior and safety boundaries.


## Asha 2.5 update

The supplied illustrated Asha hospital-support avatar is now used throughout the Vue experience, and Bangla voice output is strengthened with `bn-BD` language routing plus localized built-in communication intents. See `ASHA_2.5_FEATURES.md`.
