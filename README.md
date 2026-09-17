# NeuroBridge Asha: Multimodal Assistive Intelligence Platform

> **"NeuroBridge Asha is a multimodal assistive intelligence platform combining edge computer vision, personalized memory, retrieval-augmented knowledge, agentic AI, and cloud-native language models to transform non-verbal human signals into meaningful communication and proactive assistance."**

---

## Releases and Deployments

| Deliverable | Link |
|:---|:---|
| **Patient Android APK** | [https://github.com/mysunatislam/NeuroBridge-Asha/releases/tag/android-patient-v3.0.0](https://github.com/mysunatislam/NeuroBridge-Asha/releases/tag/android-patient-v3.0.0) |
| **Caregiver Android APK** | [https://github.com/mysunatislam/NeuroBridge-Asha/releases/tag/android-caregiver-v3.0.0](https://github.com/mysunatislam/NeuroBridge-Asha/releases/tag/android-caregiver-v3.0.0) |
| **Patient iOS IPA (unsigned)** | [https://github.com/mysunatislam/NeuroBridge-Asha/releases/tag/ios-patient-v3.0.0](https://github.com/mysunatislam/NeuroBridge-Asha/releases/tag/ios-patient-v3.0.0) |
| **Caregiver iOS IPA (unsigned)** | [https://github.com/mysunatislam/NeuroBridge-Asha/releases/tag/ios-caregiver-v3.0.0](https://github.com/mysunatislam/NeuroBridge-Asha/releases/tag/ios-caregiver-v3.0.0) |
| **Patient Web App** | [https://mysunatislam.github.io/neurobridge-asha-patient/](https://mysunatislam.github.io/neurobridge-asha-patient/) |
| **Caregiver Web App** | [https://mysunatislam.github.io/neurobridge-asha-caregiver/](https://mysunatislam.github.io/neurobridge-asha-caregiver/) |

---

## Architectural Vision: Hybrid Multimodal Assistive Intelligence

NeuroBridge Asha is not designed as "just an AI chatbot". Asha is a **multimodal assistive intelligence platform**.

**The Core Goal:**
> Asha should see, hear, understand, remember, reason, and take safe actions — while remaining affordable, privacy-aware, and capable of offline operation.

The architecture is built on **Hybrid AI**:
* **Edge AI** → Instant response (<50 ms), strict privacy, zero cloud dependency, works 100% offline.
* **Cloud AI** → Advanced medical reasoning, deep clinical synthesis, multi-turn therapy personalization.
* **Agentic Layer** → Multi-agent goal planning, tool execution, safety verification, and proactive care actions.
* **RAG Layer** → Trusted, clinical rehabilitation knowledge retrieval grounded in evidence-based medicine.

---

# NeuroBridge Asha Complete System Architecture

```text
                         USER
                          |
        ---------------------------------
        |                               |
   Camera Sensors                  Voice Input
        |                               |
        ▼                               ▼

┌────────────────────────────────────────────┐
│              PERCEPTION LAYER              │
│              (Edge AI)                     │
│                                            │
│  MediaPipe / TensorFlow Lite               │
│                                            │
│  • Hand tracking                           │
│  • Finger landmarks                        │
│  • Face landmarks (478 points)             │
│  • Eye movement                            │
│  • Blink detection                         │
│  • Smile detection                         │
│  • Pain expression                         │
│  • Head movement                           │
│  • Body posture                            │
│                                            │
└────────────────────────────────────────────┘

                     |
                     ▼

┌────────────────────────────────────────────┐
│        MULTIMODAL UNDERSTANDING ENGINE      │
│                                            │
│  Converts human signals into meaning       │
│                                            │
│  Input:                                    │
│  - Gesture                                 │
│  - Facial expression                       │
│  - Voice                                   │
│  - Context                                 │
│                                            │
│  Output:                                   │
│  "User wants water"                        │
│  "User experiencing discomfort"            │
│                                            │
└────────────────────────────────────────────┘

                     |
                     ▼

┌────────────────────────────────────────────┐
│              ASHA AI CORE                  │
│                                            │
│              Agentic AI                    │
│                                            │
│  ┌────────────────────────────────────┐    │
│  │ Personal Memory Agent              │    │
│  │                                    │    │
│  │ User profile                       │    │
│  │ Medical history                    │    │
│  │ Preferences                        │    │
│  │ Communication style                │    │
│  └────────────────────────────────────┘    │
│                                            │
│  ┌────────────────────────────────────┐    │
│  │ Reasoning Agent                    │    │
│  │                                    │    │
│  │ Understand situation               │    │
│  │ Decide next step                   │    │
│  │ Generate response                  │    │
│  └────────────────────────────────────┘    │
│                                            │
│  ┌────────────────────────────────────┐    │
│  │ Safety Agent                       │    │
│  │                                    │    │
│  │ Emergency detection                │    │
│  │ Risk assessment                    │    │
│  │ Permission checking                │    │
│  └────────────────────────────────────┘    │
│                                            │
└────────────────────────────────────────────┘

                     |
                     ▼

┌────────────────────────────────────────────┐
│                 RAG SYSTEM                 │
│          Knowledge Augmentation            │
│                                            │
│ Vector Database                            │
│                                            │
│ Stores:                                    │
│                                            │
│ • Stroke rehabilitation                    │
│ • Speech therapy                           │
│ • Autism support                           │
│ • ICU communication                        │
│ • Physiotherapy                            │
│ • Caregiver guidelines                     │
│ • User-specific instructions               │
│                                            │
└────────────────────────────────────────────┘

                     |
                     ▼

┌────────────────────────────────────────────┐
│              LLM ORCHESTRATOR              │
│                                            │
│ Selects intelligence source                │
│                                            │
│ Simple task:                               │
│ Local model (Ollama / Gemma 2 / Rule AI)   │
│                                            │
│ Complex reasoning:                         │
│ GPT-4o / Gemini Flash / Claude / Llama     │
│                                            │
└────────────────────────────────────────────┘

                     |
                     ▼

┌────────────────────────────────────────────┐
│              ACTION ENGINE                 │
│                                            │
│ Asha can perform actions                   │
│                                            │
│ Examples:                                  │
│                                            │
│ ✓ Speak response (TTS)                     │
│ ✓ Start exercise                           │
│ ✓ Call caregiver                           │
│ ✓ Send alert                               │
│ ✓ Record symptoms                          │
│ ✓ Remind medication                        │
│ ✓ Guide rehabilitation                     │
│                                            │
└────────────────────────────────────────────┘

                     |
                     ▼

             ASHA COMPANION

        Avatar + Voice + Interface

        "I noticed you look uncomfortable.
         Would you like me to call your caregiver?"
```

---

# Detailed Component Design

## 1. Edge AI Layer (Runs locally)

**Purpose:** Sub-50ms deterministic response with 100% privacy and zero cloud dependency.

### Vision Pipeline:
* **Hand Tracking (21 points):** Real-time tracking of both hands, finger articulatory movement, pinch, swipe, pointing, thumbs up/down.
* **Face Mesh (478 landmarks):** Real-time gaze tracking, blink duration and rate, smile detection, pain grimacing, head pose orientation, and subtle discomfort indicators.
* **Movement Normalization & Veto:** 2.5s sliding window filters tremor, spasticity, and involuntary twitches to distinguish intentional AAC commands from baseline movement.

---

## 2. User Digital Twin

Every patient is modeled as an individualized Digital Twin that preserves identity, care routines, and adaptive baseline parameters.

**Example Digital Twin Profile:**
```yaml
User: Rahim
Condition: Stroke Recovery (Left Hemiparesis)
Communication Modality: Right hand micro-gestures & eye-blink scanning
Language: Bangla / English bilingual
Voice Preference: Female, warm & reassuring tone
Common Requests:
  - Water (Hydration assistance)
  - Pain relief / repositioning
  - Call daughter (Caregiver contact)
Prescribed Exercises:
  - Gentle neck lateral flexion
  - Active-assisted right hand stretching
Risk Monitors:
  - Fall detection: Enabled
  - Dysphagia aspiration precautions: Active
```

This Digital Twin forms Asha's active episodic memory and context lattice.

---

## 3. Three-Tier Memory Architecture

* **Short-Term Working Memory:** Active conversation window, immediate sensor buffers, and recent pain/discomfort observations (10–30s scratchpad).
* **Long-Term Relational Memory (PostgreSQL / IndexedDB):** Verified patient preferences, medical diagnosis history, caregiver grants, medication schedules, and clinical logs.
* **Semantic Vector Memory (Vector Store / ChromaDB):** Dense semantic embeddings indexing clinical rehabilitation protocols, therapist progress notes, and prior recovery milestones.

---

## 4. RAG Knowledge Pipeline (7 Core Domains)

Asha augments generative reasoning with clinical retrieval across 7 essential domains:
1. **Stroke Rehabilitation:** Hemiparesis motor relearning, neuroplasticity exercises, and fatigue pacing.
2. **Speech Therapy:** Dysarthria oral motor drills, phoneme shaping, and pacing board techniques.
3. **Autism Support:** Sensory regulation routines, visual schedules, and low-cognitive-load communication cards.
4. **ICU Communication:** Intubation communication boards, eye-blink binary confirmations, and pain assessment scales.
5. **Physiotherapy:** Range-of-motion routines, spasticity management, and joint preservation guidelines.
6. **Caregiver Guidelines:** Safe patient transfers, pressure sore prevention, and caregiver burnout mitigation.
7. **User-Specific Instructions:** Patient-defined personal care routines, dietary restrictions, and emergency contact hierarchy.

---

## 5. Agentic AI Multi-Agent Architecture

Instead of a monolithic language model, Asha coordinates specialized autonomous agents:

```text
               ┌──────────────────────────────┐
               │         ASHA AI CORE         │
               │   (Memory, Reasoner, Safety) │
               └──────────────┬───────────────┘
                              │
         ┌────────────┬───────┴────────┬────────────┐
         ▼            ▼                ▼            ▼
   Communication    Health         Rehabilitation  Emergency
      Agent       Monitoring          Agent         Agent
                    Agent
```

* **Communication Agent:** Manages natural dialogue, real-time English/Bangla translation, and AAC phrase completion.
* **Health Monitoring Agent:** Continuously screens movement kinematics, pain indicators, fatigue, and vitals.
* **Rehabilitation Agent:** Guides step-by-step physical and speech therapy exercises:
  > *"Let's move your neck slowly. Turn right... Good. Now slightly more... Excellent."*
* **Emergency Agent:** Multi-step autonomous escalation:
  $$\text{Fall / Spasm Detected} \longrightarrow \text{Ask Patient} \xrightarrow{\text{No response}} \text{Call Caregiver} \longrightarrow \text{Dispatch Priority Alert}$$

---

## 6. Intelligent LLM Routing Strategy

To keep the platform cost-effective, low-latency, and resilient, queries are routed dynamically:

```text
                     User Request
                          │
                          ▼
                  Intelligent Router
                     /          \
                    /            \
             Simple Task      Complex Clinical
             & Offline        Reasoning
                  │                  │
                  ▼                  ▼
             Local Model         Cloud LLM
          (Gemma 2 / Rules)   (Gemini / Claude / GPT)
```

---

## 7. Action Engine

Asha directly triggers safe, verified actuators:
* ✓ **Speak Response:** Neural TTS with empathetic prosody.
* ✓ **Start Exercise:** Launches interactive rehab guidance.
* ✓ **Call Caregiver:** Automated emergency telephony/VoIP trigger.
* ✓ **Send Alert:** High-priority caregiver notifications.
* ✓ **Record Symptoms:** Logs pain, tremors, or fatigue in clinical history.
* ✓ **Remind Medication:** Scheduled alerts with dosage and ingestion confirmation.
* ✓ **Guide Rehabilitation:** Interactive feedback loop tracking repetition and form.

---

## 8. Hardware Architecture (Wheelchair Integration)

Designed for wheelchair deployment and bedside hospital care:

```text
              Raspberry Pi 5 / 4B
                       │
        ───────────────┼───────────────
        │              │              │
  Camera Module    Coral TPU      Sunlight-Readable
   (NoIR/RGB)     Accelerator      Caption Display
        │              │              │
        ▼              ▼              ▼
  Sub-50ms CV    TFLite Edge     Idempotent
   Landmarks      Inference       Captions
                       │
        ───────────────┼───────────────
        │                             │
    Directional Microphone       Isolated BMS /
    & Amplified Speaker        Wheelchair Telemetry
```

---

## 9. Offline Resilience Mode

In clinical wards, rural environments, or during transit where internet access is unavailable:
* MediaPipe vision + local gesture classifiers run entirely on device.
* The local RAG engine retrieves embedded clinical protocols with zero latency.
* Basic Asha companion interacts with full conversational empathy.
* When internet returns, all offline symptom logs and events sync seamlessly to the cloud control plane.

---

## 4-Phase Roadmap

* **Phase 1 (Current):** Flutter + MediaPipe Edge Vision + Asha Companion Avatar + Voice Synthesis + Intent Pipeline.
* **Phase 2:** Multi-tier Memory + 7-Domain Clinical RAG + User Digital Twin Engine.
* **Phase 3:** Autonomous Multi-Agent Actions + Caregiver Web/Mobile Portal Integration + Real-time Telemetry.
* **Phase 4:** Raspberry Pi Wheelchair Hardware Bundle + Offline Coral TPU Acceleration + Hospital Clinical Deployment.

---

## Quick Start & Verification

### Web PWA (`apps/web`):
```powershell
.\scripts\bootstrap.ps1
Set-Location .\apps\web
npm.cmd run dev
```

### Native Flutter Client (`apps/mobile`):
```powershell
Set-Location .\apps\mobile
flutter.bat run
```

### Run Automated Tests:
```powershell
Set-Location .\apps\mobile
flutter.bat test
```

For in-depth architectural contracts and clinical defense specifications, see:
* [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
* [docs/MULTIMODAL_ASSISTIVE_INTELLIGENCE_PLATFORM.md](docs/MULTIMODAL_ASSISTIVE_INTELLIGENCE_PLATFORM.md)
* [docs/HARDWARE_ARCHITECTURE.md](docs/HARDWARE_ARCHITECTURE.md)
* [docs/INTENT_RECOGNITION.md](docs/INTENT_RECOGNITION.md)
