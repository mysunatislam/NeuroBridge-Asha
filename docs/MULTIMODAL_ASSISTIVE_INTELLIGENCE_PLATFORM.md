# NeuroBridge Asha: Multimodal Assistive Intelligence Platform
## Technical Architecture, Multi-Agent Orchestration & Clinical Deployment Specification

> **Platform Mission Statement:**
> "NeuroBridge Asha is a multimodal assistive intelligence platform combining edge computer vision, personalized memory, retrieval-augmented knowledge, agentic AI, and cloud-native language models to transform non-verbal human signals into meaningful communication and proactive assistance."

---

## 1. System Vision & Paradigm Shift

Conventional assistive technologies treat non-verbal individuals and ALS/stroke survivors as passive users of static word-boards or brittle keyword chatbots. **NeuroBridge Asha** re-architects assistive computing as an **active, multimodal intelligent platform** that:
1. **Sees & Tracks:** Real-time on-device edge perception of 21-point dual hand landmarks and 478-point facial mesh.
2. **Hears & Translates:** Resilient voice perception and low-latency multilingual speech synthesis with Bengali and English clinical scaffolding.
3. **Understands & Synthesizes:** Fuses gestures, facial grimaces/smiles, blink rates, and temporal context into high-order semantic intent.
4. **Remembers:** Maintains a persistent 3-tier memory system and patient Digital Twin to track clinical history, recovery progression, and individual habits.
5. **Reasons:** Uses an intelligent router to delegate routine tasks locally and deep clinical reasoning to cloud LLMs (Gemini, Claude, GPT).
6. **Acts Safely:** Triggers validated physical and communication actuators (speech, rehab coaching, caregiver calls, emergency escalations).

---

## 2. Platform Architecture Diagram

```text
                                       PATIENT
                                          │
                  ┌───────────────────────┴───────────────────────┐
                  ▼                                               ▼
         Camera Video Feed                               Microphone Audio
                  │                                               │
┌─────────────────┴───────────────────────────────────────────────┴─────────────────┐
│                           EDGE PERCEPTION LAYER                                   │
│                            (MediaPipe / TFLite)                                   │
│                                                                                   │
│  Dual Hand Tracking (21 pts)          Face Mesh (478 pts)      Acoustic Features   │
│  • Micro-finger flexion                • Eye blink & gaze       • Voiced pitch     │
│  • Pinch, swipe, thumbs up/down        • Smile & grimace        • Dysarthric sound │
│  • Hand raise kinematics               • Head pose / nod        • Phoneme burst    │
│                                                                                   │
│  Temporal Feature Window (2.5s / 4Hz) ─> Abnormal Spasm / Tremor Veto Filter     │
└─────────────────────────────────────────┬─────────────────────────────────────────┘
                                          │
                                          ▼
┌───────────────────────────────────────────────────────────────────────────────────┐
│                    MULTIMODAL UNDERSTANDING ENGINE                                │
│                                                                                   │
│  Inputs: Hand gestures + Facial Affect + Acoustic Cues + Patient Context          │
│  Processing: Multimodal Confidence Fusion & Intent Verification                   │
│  Outputs: High-level Semantics ("User wants water", "Pain/discomfort alert")      │
└─────────────────────────────────────────┬─────────────────────────────────────────┘
                                          │
                                          ▼
┌───────────────────────────────────────────────────────────────────────────────────┐
│                              ASHA AI CORE                                         │
│                                                                                   │
│  ┌───────────────────────┐   ┌───────────────────────┐   ┌─────────────────────┐  │
│  │ Personal Memory Agent │   │    Reasoning Agent    │   │    Safety Agent     │  │
│  │ • Digital Twin Model  │   │ • Situation Synthesis │   │ • Gating & Vetoes   │  │
│  │ • 3-Tier Memory Store │   │ • Multi-turn Dialogue │   │ • Escalation Failsafe│  │
│  └───────────────────────┘   └───────────────────────┘   └─────────────────────┘  │
│                                                                                   │
│  ┌─────────────────────────────────────────────────────────────────────────────┐  │
│  │                       SPECIALIZED AGENT QUADRANT                            │  │
│  │                                                                             │  │
│  │  [Communication Agent]    [Health Monitoring]   [Rehabilitation] [Emergency]│  │
│  │  • Dialogue & AAC         • Pain & Fatigue      • Guided Drills  • Multi-step│  │
│  │  • Bengali/Eng Speech     • Spasm Detection     • Progress Tracking Alerting│  │
│  └─────────────────────────────────────────────────────────────────────────────┘  │
└───────────────────────┬───────────────────────────────────┬───────────────────────┘
                        │                                   │
                        ▼                                   ▼
┌───────────────────────────────────────────┐   ┌───────────────────────────────────┐
│                RAG SYSTEM                 │   │         LLM ORCHESTRATOR          │
│     Clinical Knowledge Augmentation       │   │         Intelligent Router        │
│                                           │   │                                   │
│  Stores 7 Curated Medical Domains:        │   │  Simple / Offline:                │
│  1. Stroke rehabilitation                 │   │  Local Deterministic / Gemma 2    │
│  2. Speech therapy & aphasia              │   │                                   │
│  3. Autism support & sensory regulation   │   │  Complex Clinical Reasoning:      │
│  4. ICU communication boards              │   │  Gemini Flash / Claude / GPT-4o   │
│  5. Physiotherapy & joint mobilization    │   │                                   │
│  6. Caregiver guidelines & ergonomics     │   │  Zero-latency offline fallback    │
│  7. User-specific instructions & care     │   │  when network connectivity drops  │
└───────────────────────────────────────────┘   └─────────────────┬─────────────────┘
                                                                  │
                                                                  ▼
┌───────────────────────────────────────────────────────────────────────────────────┐
│                             ACTION ENGINE                                         │
│                                                                                   │
│  ✓ Speak Response (Neural TTS with emotional prosody)                             │
│  ✓ Start Exercise (Turn-by-turn physical or oral-motor drill guidance)            │
│  ✓ Call Caregiver (Direct telephony or authenticated VoIP alert)                  │
│  ✓ Send Alert (Caregiver portal push notification)                                │
│  ✓ Record Symptoms (Structured clinical telemetry: pain, fatigue, tremor)         │
│  ✓ Remind Medication (Prescription dosage schedule & adherence checks)           │
│  ✓ Guide Rehabilitation (Pacing feedback & repetition counter)                    │
└─────────────────────────────────────────┬─────────────────────────────────────────┘
                                          │
                                          ▼
┌───────────────────────────────────────────────────────────────────────────────────┐
│                             ASHA COMPANION INTERFACE                              │
│                                                                                   │
│  Proactive Conversational Avatar + Natural Voice + Wheelchair Caption Bridge      │
│  "I noticed you look uncomfortable. Would you like me to call your caregiver?"    │
└───────────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Detailed Component Specifications

### 3.1 Edge AI Perception Layer
Runs entirely on device (Smartphone / Raspberry Pi 5) with sub-50ms latency.
* **Hand Tracking:** Extracts 21 3D Cartesian coordinates per hand. Identifies discrete micro-gestures (finger taps, pinches, thumb gestures, pointing).
* **Face Mesh (478 Landmarks):**
  - Eye Aspect Ratio (EAR) for voluntary vs involuntary blink detection.
  - Mouth Aspect Ratio (MAR) for open-mouth intents or speech motor attempts.
  - Eyebrow displacement & nasolabial furrow calculation for non-verbal pain grimacing (PAINAD scale alignment).
  - Head pose orientation (yaw, pitch, roll) for intentional nod/turn commands.
* **Temporal Stability Window:** Aggregates 2.5 seconds (30–60 frames) to calculate movement high-frequency ratios and reject twitches or fasciculations.

### 3.2 User Digital Twin Model
The platform models each patient as an adaptive Digital Twin:
* **Identification:** Name, age, condition (e.g. Ischemic Stroke with Left Hemiparesis, ALS, Cerebral Palsy).
* **Primary Communication Modality:** Calibrated hand gestures, eye-blink scanning, or dual-switch triggers.
* **Linguistic Preference:** Native language (e.g. Bangla / English), cadence, tone preference.
* **Personal Common Vocabulary:** High-priority biological needs (`Water`, `Pain`, `Call Caregiver`, `Reposition`).
* **Prescribed Rehabilitation Protocol:** Tailored physical exercises (e.g., gentle neck lateral flexion, isometric wrist extensions).
* **Clinical Safety Flags:** Fall risk alert active, dysphagia aspiration risk active, dysreflexia monitoring.

### 3.3 Three-Tier Memory System
1. **Short-Term Working Memory:** In-memory rolling scratchpad (10–30s) tracking recent statements, immediate pain expressions, and active dialogue topics.
2. **Long-Term Relational Memory:** Persistent store (PostgreSQL in cloud, encrypted SQLite/IndexedDB on device) containing validated profile settings, caregiver contact hierarchy, medication schedules, and cumulative usage metrics.
3. **Semantic Memory:** Vector store indexing evidence-based therapy literature, past clinical session summaries, and individual behavioral baselines.

### 3.4 7-Domain Clinical RAG Augmentation
Asha's clinical knowledge repository covers seven critical domains:
1. `stroke_rehabilitation`: Spasticity reduction, bilateral motor facilitation, task-oriented arm reaching.
2. `speech_therapy`: Oral-motor exercises, vocal intensity drills (LSVT-inspired), dysarthric compensatory strategies.
3. `autism_support`: Predictable routines, sensory de-escalation, visual communication scaffolds.
4. `icu_communication`: Quick-select physiological charts, eye-gaze spelling confirmation, pain scale rating.
5. `physiotherapy`: Passive range of motion, ergonomic positioning to avoid contractures, posture realignment.
6. `caregiver_guidelines`: Body mechanics during transfers, pressure injury staging and offloading schedules, emotional burnout relief.
7. `user_specific_instructions`: Individualized care directives, family names, dietary texture modifications (e.g. nectar-thick fluids).

### 3.5 Specialized Multi-Agent System
* **Communication Agent:** Conversational partner that handles turn-taking, phrase prediction, and bilingual English-Bangla translation.
* **Health Monitoring Agent:** Analyzes passive video stream for pain grimacing, fatigue onset, and abnormal rhythmic jerking indicative of seizure or distress.
* **Rehabilitation Agent:** Interactively leads therapy exercises:
  > *"Let's move your neck slowly. Turn right... Good. Now hold for three seconds... Excellent work."*
* **Emergency Agent:** Autonomous safety escalation:
  1. Detects abnormal state (prolonged closed eyes, fall, repetitive spasm).
  2. Prompts user: *"Are you okay? Blink twice or tap to dismiss."*
  3. If no confirmation within 8 seconds: Immediately triggers caregiver phone call and dispatches high-priority alert with vitals.

### 3.6 Wheelchair Hardware Architecture
* **Compute Unit:** Raspberry Pi 5 (8GB) with dedicated Coral Edge TPU accelerator.
* **Optical Sensor:** Raspberry Pi NoIR Camera Module v3 mounted with flexible gooseneck bracket toward patient's face and lap.
* **Audio Transducers:** Directional noise-canceling microphone array + 5W high-efficiency speaker.
* **Display Unit:** 7-inch sunlight-readable 800×480 capacitive touchscreen displaying large captions and system status.
* **Telemetry Bridge:** Isolated optocoupled interface reading battery voltage and wheelchair power state.

---

## 4. Releases and Deployments Reference

| Target Platform | Package Format | Distribution Link |
|:---|:---|:---|
| Android Patient Client | Signed APK | [https://github.com/mysunatislam/NeuroBridge-Asha/releases/tag/android-patient-v3.0.0](https://github.com/mysunatislam/NeuroBridge-Asha/releases/tag/android-patient-v3.0.0) |
| Android Caregiver Client | Signed APK | [https://github.com/mysunatislam/NeuroBridge-Asha/releases/tag/android-caregiver-v3.0.0](https://github.com/mysunatislam/NeuroBridge-Asha/releases/tag/android-caregiver-v3.0.0) |
| iOS Patient Client | Unsigned IPA | [https://github.com/mysunatislam/NeuroBridge-Asha/releases/tag/ios-patient-v3.0.0](https://github.com/mysunatislam/NeuroBridge-Asha/releases/tag/ios-patient-v3.0.0) |
| iOS Caregiver Client | Unsigned IPA | [https://github.com/mysunatislam/NeuroBridge-Asha/releases/tag/ios-caregiver-v3.0.0](https://github.com/mysunatislam/NeuroBridge-Asha/releases/tag/ios-caregiver-v3.0.0) |
| Patient Web PWA | Web App | [https://mysunatislam.github.io/neurobridge-asha-patient/](https://mysunatislam.github.io/neurobridge-asha-patient/) |
| Caregiver Web Portal | Web App | [https://mysunatislam.github.io/neurobridge-asha-caregiver/](https://mysunatislam.github.io/neurobridge-asha-caregiver/) |
