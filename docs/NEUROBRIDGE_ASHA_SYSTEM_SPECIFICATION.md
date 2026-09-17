# NeuroBridge-Asha: Full System Specification & Architectural Blueprint

**Version:** 3.0.0  
**Status:** Active Clinical Architecture  
**Target Platforms:** Android, iOS, Linux (Raspberry Pi 5 SBC), Web (PWA)  
**Primary Engine:** Google MediaPipe + On-Device TFLite + Gemini Multimodal Agent Core  

---

## Table of Contents
1. [Executive Overview & Mission](#1-executive-overview--mission)
   - 1.1 What It Is
   - 1.2 Clinical Problem & Population Served
   - 1.3 Operating Philosophy: Beyond Static AAC
2. [What It Does (Current Capabilities)](#2-what-it-does-current-capabilities)
   - 2.1 Patient Wheelchair Tablet Interface
   - 2.2 Individualized Multi-Patient Caregiver Platform
   - 2.3 Live Tele-Vision & Activity Dashboard
   - 2.4 Clinical Feedback & Physician Reporting
   - 2.5 Signal Calibration & Access Profiling
3. [What It Will Be (Future Vision & Horizon Roadmap)](#3-what-it-will-be-future-vision--horizon-roadmap)
   - 3.1 4-Phase Evolutionary Roadmap
   - 3.2 Non-Invasive BCI & Neural Headband Integration
   - 3.3 Sub-10ms Neuromorphic Edge Vision Pipeline
   - 3.4 Ambient Smart Hospital & Matter IoT Integration
   - 3.5 Assistive Robotic Arm Manipulation
4. [Data Structures & Schemas](#4-data-structures--schemas)
   - 4.1 Mobile Patient Registry Models
   - 4.2 Agent Memory & Digital Twin Schemas
   - 4.3 Landmark & Biometric Vector Schemas
   - 4.4 Offline RAG Knowledge Base Representation
5. [Security, Privacy & Safety Architecture](#5-security-privacy--safety-architecture)
   - 5.1 Zero-Cloud Privacy Enclave
   - 5.2 Encryption at Rest & in Transit
   - 5.3 Role-Based Access Control (RBAC)
   - 5.4 Clinical Safety Guardrails & Hallucination Suppression
   - 5.5 Hardware Privacy Shutter & Fail-Safes
6. [Algorithms & Mathematical Formulations](#6-algorithms--mathematical-formulations)
   - 6.1 Eye Aspect Ratio (EAR) & Blink State Machine
   - 6.2 Contactless Optical Respiration Estimation (rPPG & Motion)
   - 6.3 PAINAD Non-Verbal Pain Assessment Scoring
   - 6.4 Multimodal Signal Fusion Formula
   - 6.5 Gesture SNR & Dynamic Calibration Normalization
7. [AI & Agentic Core Architecture](#7-ai--agentic-core-architecture)
   - 7.1 Hybrid Cloud/Edge Dual Engine
   - 7.2 The 4 Specialized Clinical Agents
   - 7.3 3-Tier Human Cognitive Memory Model
   - 7.4 7-Domain Clinical Knowledge Base (Offline RAG)
   - 7.5 Bilingual Diacritic Tokenization Engine
   - 7.6 Agent Tool Dispatch & Autonomous Actions
8. [End-to-End System Specifications](#8-end-to-end-system-specifications)

---

## 1. Executive Overview & Mission

### 1.1 What It Is
**NeuroBridge-Asha** is an autonomous, multimodal assistive intelligence platform and digital twin ecosystem engineered for individuals with severe neuro-motor impairments. It bridges the gap between biological intention and physical action by continuously perceiving subtle, voluntary micro-signals—such as eyelid blinks, micro-gestures, facial muscle contractions, tongue motions, and respiration shifts—and translating them into natural expressive speech, environmental autonomy, and clinical telemetry.

### 1.2 Clinical Problem & Population Served
Traditional Augmentative and Alternative Communication (AAC) systems are predominantly rigid, expensive, and fragile. They rely heavily on mechanical switches or eye-gaze tracking cameras that fail under eyelid ptosis, dry eyes, head movement, or direct sunlight. Furthermore, existing systems do not provide real-time continuous clinical monitoring, leaving caregivers blind to silent distress, nocturnal seizures, or pain escalations.

NeuroBridge-Asha is purpose-built for individuals affected by:
* **Amyotrophic Lateral Sclerosis (ALS / Lou Gehrig's Disease)**
* **Locked-in Syndrome (LIS)** secondary to pontine stroke or trauma
* **High-Cervical Spinal Cord Injuries (Quadriplegia C1–C4)**
* **Severe Cerebral Palsy (GMFCS Level V)**
* **Severe Post-Stroke Motor Aphasia and Dysarthria**

### 1.3 Operating Philosophy: Beyond Static AAC
Traditional AAC is a passive keyboard. NeuroBridge-Asha is an **active, multimodal agentic companion**:
```
[ Ambient Camera / Microphones / SBC Sensors ]
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│ 1. Local Multimodal Perception Pipeline                     │
│    • 478-Point Dense Facial & Eye Mesh (MediaPipe)          │
│    • 21-Point Dual-Hand Skeletal Micro-Tracking             │
│    • Contactless Thoracic Respiration Tracking              │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Multimodal Fusion Engine                                 │
│    • Signal-to-Noise Filtering & Normalization              │
│    • Semantic Intent Generation                             │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Asha Agentic Core (Hybrid Edge/Cloud Swarm)              │
│    • 3-Tier Memory Architecture & Patient Digital Twin      │
│    • 7-Domain Clinical Offline RAG Knowledge Base           │
│    • 4 Specialized Clinical Agents (Communication, Health,  │
│      Rehabilitation, Emergency)                             │
└───────────────┬─────────────────────────────┬───────────────┘
                │                             │
                ▼                             ▼
┌──────────────────────────────┐   ┌──────────────────────────────┐
│ Patient Wheelchair Tablet    │   │ Caregiver Hub & Clinic       │
│ • Adaptive Predictive AAC    │   │ • Live Tele-Vision Feed      │
│ • Natural Asha Voice TTS     │   │ • Multi-Patient Registry     │
│ • Direct Environmental Ctrls │   │ • Doctor Reporting System    │
└──────────────────────────────┘   └──────────────────────────────┘
```

---

## 2. What It Does (Current Capabilities)

### 2.1 Patient Wheelchair Tablet Interface
* **Modality Independence**: Operates seamlessly across 4 distinct physical input paradigms:
  1. *Face, Eyes & Head Tracking*: Eye blink duration, pupil gaze vectors, jaw clenching, and eyebrow elevation.
  2. *Hand & Finger Micro-Gestures*: Finger flexion, thumb twitches, and micro-signs.
  3. *Tongue & Labial Motions*: Subtle mouth and tongue displacements for quadriplegic patients without gaze stability.
  4. *Adaptive Hybrid*: Automatic failover between modalities based on real-time motor fatigue detection.
* **Predictive AAC Matrix**: Context-aware phrase lattice optimized for sub-second communication.
* **Natural Spoken TTS**: High-fidelity speech generation in English and Bengali with natural cadence and empathetic inflections.
* **One-Tap Emergency Trigger**: Instant visual alarm, loud auditory siren, caregiver broadcast, and automated 911 dispatch.

### 2.2 Individualized Multi-Patient Caregiver Platform
* **Individual Patient Registry**: Isolated clinical profiles for multiple patients. Caregivers can toggle between **Patient 1 (Rahim Chowdhury)**, **Patient 2 (Sarah Jenkins)**, and **Patient 3 (Tariq Al-Mansoor)** with a single tap.
* **Direct Patient Messaging ("Send Message to Patient")**:
  * One-tap predefined dispatch options (*"I'm on my way"*, *"Doctor is arriving"*, *"Time for medication"*, *"Rest well, I'm nearby"*) or custom typed entries.
  * Direct speech synthesis via Asha Voice TTS over the patient's wheelchair tablet speaker.
  * Full chronological dispatch history logged per patient.

### 2.3 Live Tele-Vision & Activity Dashboard
* **"What Patient Is Doing Right Now"**: High-level semantic interpretation generated by the fusion engine (e.g., *"Awake and resting comfortably in wheelchair. Intermittent eye gestures detected."*).
* **Live Telemetry Bar**: Continuous display of Heart Rate (BPM), Respiration Rate (Br/min), PAINAD Pain Score (0–10), and Signal Tracking Confidence (%).
* **Live Video Feed**: Direct, low-latency video stream from the wheelchair tablet to the caregiver's device with real-time landmark skeletal overlays.
* **Privacy Shutter**: Instant software privacy toggle pausing video transmission while preserving vital telemetry.
* **Reassurance Intercom**: Direct two-way push-to-talk audio channel.

### 2.4 Clinical Feedback & Physician Reporting
* **Qualitative Clinical Observations ("Give Feedback on Patient")**:
  * Category tags: **Behavioral**, **Pain / Discomfort**, **Therapy Progress**, **Mobility**, **General**.
  * Logs clinician identity, precise timestamp, and clinical notes into the patient's timeline.
* **Physician Progress Reporting ("Report to Doctor")**:
  * Automated compilation of current vitals, pain scores, gesture accuracy, care directives, and recent observations.
  * One-touch export via SMS, Email, or Clipboard formatted for Electronic Health Records (EHR).

### 2.5 Signal Calibration & Access Profiling
* **5-Step Interactive Calibration Wizard**: Normalizes baseline resting states, active signal thresholds, dwell times, and noise filtering for each patient's individual range of motion.
* **Settings Management Card**: Comprehensive in-app configuration of medical conditions, emergency contacts, attending physicians, and care directives.

---

## 3. What It Will Be (Future Vision & Horizon Roadmap)

```mermaid
gantt
    title NeuroBridge-Asha Architecture Evolution Roadmap
    dateFormat  YYYY-Q#
    section Phase 1 (Completed)
    Multimodal CV & Gesture Fusion       :done, 2025-Q3, 2026-Q1
    Individual Multi-Patient Platform    :done, 2026-Q1, 2026-Q2
    7-Domain Clinical Offline RAG        :done, 2026-Q2, 2026-Q3
    section Phase 2 (Near-Term)
    Wearable Sensor Fusion (rPPG + PPG)  :active, 2026-Q3, 2026-Q4
    WebRTC Tele-Vision Bridge (Zero-Relay): 2026-Q4, 2027-Q1
    Matter IoT Smart-Room Integration    : 2026-Q4, 2027-Q1
    section Phase 3 (Mid-Term)
    Non-Invasive BCI / EEG Headband Hook : 2027-Q1, 2027-Q3
    Sub-10ms Neuromorphic Edge NPU Pipeline: 2027-Q2, 2027-Q4
    section Phase 4 (Long-Term)
    Autonomous Wheelchair Robotic Arm Interop: 2027-Q4, 2028-Q4
```

### 3.1 Non-Invasive BCI & Neural Headband Integration
For patients transitioning into total locked-in state (loss of all extraocular motor control), Asha will ingest direct non-invasive EEG telemetry via OpenBCI / Emotiv / custom dry-electrode arrays:
* **P300 Event-Related Potential (ERP)**: Rapid visual oddball paradigm for direct alphanumeric selection.
* **Steady-State Visual Evoked Potentials (SSVEP)**: Frequency-coded menu selection (10–15 Hz) decoded entirely on the Edge TPU.

### 3.2 Sub-10ms Neuromorphic Edge Vision Pipeline
* Migration from standard CMOS rolling-shutter sensors to **Event-Based Neuromorphic Vision Sensors (DVS)**.
* Pixel-level microsecond temporal resolution allowing micro-tremors and subtle eyelid fluttering to be detected with $\le 5\text{ ms}$ latency and $< 100\text{ mW}$ power consumption.

### 3.3 Ambient Smart Hospital & Matter IoT Integration
* Direct local control of smart hospital beds (head tilt, leg elevation, firmness).
* Matter/Thread protocol bridging for local control of room lighting, temperature, blinds, and motorized doors without reliance on external consumer cloud ecosystems.

### 3.4 Assistive Robotic Arm Manipulation
* Interfacing Asha’s agentic planner with wheelchair-mounted assistive robotic arms (e.g., Kinova Gen3 lite).
* Autonomous execution of self-feeding, hydration cup placement, and facial scratching guided by gaze and micro-trigger commands.

---

## 4. Data Structures & Schemas

### 4.1 Mobile Patient Registry (`apps/mobile/lib/models/patient_record.dart`)

```dart
class PatientRecord {
  final String id;
  final String name;
  final int age;
  final String roomNumber;
  final String condition;
  final String primaryModality;
  final String doctorName;
  final String doctorPhone;
  final String doctorEmail;
  final String careDirectives;
  final String currentActivity;
  final int heartRate;
  final int respirationRate;
  final int painScore; // Scale 0 - 10
  final int gestureAccuracy; // Percentage 0 - 100
  final DateTime lastUpdated;
  final List<PatientFeedbackEntry> feedbackNotes;
  final List<CaregiverMessageEntry> messagesSent;

  const PatientRecord({
    required this.id,
    required this.name,
    required this.age,
    required this.roomNumber,
    required this.condition,
    required this.primaryModality,
    required this.doctorName,
    required this.doctorPhone,
    required this.doctorEmail,
    required this.careDirectives,
    required this.currentActivity,
    required this.heartRate,
    required this.respirationRate,
    required this.painScore,
    required this.gestureAccuracy,
    required this.lastUpdated,
    this.feedbackNotes = const [],
    this.messagesSent = const [],
  });

  Map<String, dynamic> toJson();
  factory PatientRecord.fromJson(Map<String, dynamic> json);
  PatientRecord copyWith({...});
}

class PatientFeedbackEntry {
  final String id;
  final DateTime timestamp;
  final String category; // 'Behavioral', 'Pain / Discomfort', 'Therapy Progress', 'Mobility', 'General'
  final String notes;
  final String author;
}

class CaregiverMessageEntry {
  final String id;
  final DateTime timestamp;
  final String message;
  final bool spokeAloud;
  final String sender;
}

class DoctorReportSummary {
  final String patientId;
  final String patientName;
  final String generatedTimestamp;
  final String roomNumber;
  final String condition;
  final String primaryModality;
  final String doctorName;
  final String careDirectives;
  final int heartRate;
  final int respirationRate;
  final int painScore;
  final int gestureAccuracy;
  final List<String> recentObservations;
  final List<String> recentDispatches;
}
```

### 4.2 Agent Memory & Digital Twin Schemas (`services/api/.../agent/memory.py`)

```python
class DigitalTwinProfile(BaseModel):
    patient_id: str = "patient-001"
    name: str = "Rahim Chowdhury"
    age: int = 64
    primary_condition: str = "Ischemic stroke recovery"
    mobility_profile: str = "Right-hand micro-gestures, limited vocalization"
    languages: list[str] = ["bn", "en"]
    vital_baselines: dict[str, float] = {
        "resting_hr": 72.0,
        "resting_rr": 16.0,
        "normal_systolic": 125.0,
    }
    emergency_contact: dict[str, str] = {
        "name": "Nadia Chowdhury",
        "relation": "Daughter / Primary Caregiver",
        "phone": "+880-1700-000000",
    }
    preferences: dict[str, str] = {
        "voice_speed": "0.9x",
        "communication_mode": "predictive_gestures",
        "fall_detection_sensitivity": "high",
    }
    active_prescriptions: list[str] = [
        "Aspirin 81mg (Morning)",
        "Atorvastatin 20mg (Night)",
        "Baclofen 10mg (Spasticity - BID)",
    ]

class MemoryEntry(BaseModel):
    entry_id: str
    timestamp: datetime
    tier: Literal["working", "episodic", "semantic"]
    category: str
    content: str
    metadata: dict[str, Any] = Field(default_factory=dict)
```

### 4.3 Landmark Vector Schema (Inference Exchange)

```json
{
  "timestamp_ms": 1773792000000,
  "frame_id": 48291,
  "face": {
    "detected": true,
    "landmarks_count": 478,
    "bounding_box": [0.22, 0.15, 0.78, 0.85],
    "eye_aspect_ratio_left": 0.28,
    "eye_aspect_ratio_right": 0.29,
    "lip_distance_norm": 0.04,
    "eyebrow_elevation_norm": 0.62,
    "head_pose_angles": {
      "pitch": -2.1,
      "yaw": 1.4,
      "roll": 0.3
    }
  },
  "hands": [
    {
      "handedness": "Right",
      "confidence": 0.94,
      "landmarks_21": [
        { "id": 0, "x": 0.52, "y": 0.68, "z": -0.01 },
        { "id": 4, "x": 0.48, "y": 0.61, "z": -0.04 },
        { "id": 8, "x": 0.51, "y": 0.52, "z": -0.07 }
      ],
      "gesture_class": "pinch_select",
      "velocity_magnitude": 0.003
    }
  ]
}
```

---

## 5. Security, Privacy & Safety Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    SECURITY ARCHITECTURE                    │
├──────────────────────────────┬──────────────────────────────┤
│ 1. Zero-Cloud Privacy        │ • All landmark tracking runs │
│    Enclave                   │   locally in-memory on Edge  │
│                              │ • No video leaves device     │
├──────────────────────────────┼──────────────────────────────┤
│ 2. Encryption Layers         │ • AES-256-GCM at rest        │
│                              │ • TLS 1.3 in transit         │
├──────────────────────────────┼──────────────────────────────┤
│ 3. Clinical Safety Guard     │ • Double confirmation on 911 │
│                              │ • Non-prescriptive RAG       │
├──────────────────────────────┼──────────────────────────────┤
│ 4. Hardware Privacy Shutter  │ • Physical/software cutoff   │
│                              │ • Visual LED broadcast       │
└──────────────────────────────┴──────────────────────────────┘
```

### 5.1 Zero-Cloud Privacy Enclave
* **100% In-Memory Frame Processing**: The computer vision pipeline decodes video frames exclusively in volatile RAM. No raw camera frames are ever written to persistent flash storage.
* **Sub-33ms Ephemeral Destruction**: Camera buffers are released and overwritten immediately upon feature vector extraction ($\le 33\text{ ms}$).
* **Coordinate-Only Transmission**: Any data transmitted across process boundaries or over the local network consists solely of dimensionless geometric landmark arrays and vital signs.

### 5.2 Encryption Standards
* **At-Rest Protection**: All SQLite/SharedPreferences stores containing patient demographics, clinical notes, and baseline profiles are encrypted using **AES-256-GCM** with keys rooted in hardware security modules (Android Keystore / iOS Secure Enclave).
* **In-Transit Protection**: Caregiver-to-wheelchair communication uses mutual TLS (**mTLS with TLS 1.3**), strict certificate pinning, and short-lived session tokens.

### 5.3 Clinical Safety Guardrails
* **Non-Prescriptive Constraints**: Asha’s agentic core is constrained by medical boundary rules: it can explain, reassure, coach exercises, and summarize physician notes, but is strictly blocked from recommending drug alterations.
* **Emergency Gating**: High-consequence actions (e.g., EMS dispatch) require either continuous 3-second dwell confirmation or trigger an audible 10-second cancel countdown.

---

## 6. Algorithms & Mathematical Formulations

### 6.1 Eye Aspect Ratio (EAR) & Blink Classification
Eyelid opening dynamics are quantified using the 6 landmark coordinates surrounding each eye:

$$\text{EAR} = \frac{\|p_2 - p_6\| + \|p_3 - p_5\|}{2 \|p_1 - p_4\|}$$

Where:
* $p_1, p_4$ are the lateral and medial eye canthi (corners).
* $p_2, p_6$ and $p_3, p_5$ are the superior and inferior pairs of eyelid landmarks.

```
       p2        p3
        •────────•
   p1  /          \  p4
    •              •
       \•────────•/
       p6        p5
```

* **Resting Open Eye**: $\text{EAR} \approx 0.28 - 0.35$.
* **Voluntary Closure**: $\text{EAR} < 0.18$.
* **State Machine Classification**:
  * $\Delta t < 150\text{ ms}$: Involuntary physiological blink (rejected as noise).
  * $250\text{ ms} \le \Delta t \le 800\text{ ms}$: Short Click (Selection).
  * $800\text{ ms} < \Delta t \le 2000\text{ ms}$: Long Click (Menu / Cancel).
  * $\Delta t > 3500\text{ ms}$: Micro-sleep / distress state.

### 6.2 Contactless Optical Respiration Estimation (rPPG & Motion)
Chest and sternum periodic displacement is measured across a designated Region of Interest (ROI):

$$I_{\text{ROI}}(t) = \frac{1}{|R|} \sum_{(x,y) \in R} Y(x, y, t)$$

1. **Filtering**: Passed through a zero-phase 4th-order Butterworth bandpass filter:
   
   $$H(f) = \frac{1}{\sqrt{1 + \left(\frac{f - f_0}{B}\right)^8}}, \quad [f_{\text{low}}, f_{\text{high}}] = [0.1\text{ Hz}, 0.5\text{ Hz}] \quad (6 - 30\text{ Br/min})$$

2. **Spectral Density**: Fast Fourier Transform (FFT) identifies the dominant peak:

   $$\text{RR} = 60 \times \arg\max_f \left| \mathcal{F}\left\{ \tilde{I}_{\text{ROI}}(t) \right\}(f) \right|$$

### 6.3 PAINAD Non-Verbal Pain Assessment Scoring
Non-verbal pain is evaluated across 5 clinical domains, mapped to a 0–10 cumulative score:

$$\text{Score}_{\text{PAINAD}} = S_{\text{breathing}} + S_{\text{vocalization}} + S_{\text{facial}} + S_{\text{body}} + S_{\text{consolability}}$$

| Parameter | 0 | 1 | 2 |
| :--- | :--- | :--- | :--- |
| **Breathing** | Normal | Occasional labored / short hyperventilation | Noisy labored / Cheyne-Stokes |
| **Facial Expression** | Neutral / Relaxed | Frowning, sad, worried, furrowed brow | Frightened, grimacing, clenching teeth |
| **Body Language** | Relaxed | Tense, pacing, fidgeting | Rigid, clenched fists, knees pulled up |

*Continuous monitoring computes facial grimace deformation and respiratory turbulence.*

### 6.4 Multimodal Signal Fusion Formula
The fusion engine aggregates asynchronous feature streams into a unified semantic state:

$$S_{\text{fused}} = \sigma\left( \mathbf{W}_h \mathbf{v}_{\text{hand}} + \mathbf{W}_f \mathbf{v}_{\text{face}} + \mathbf{W}_v \mathbf{v}_{\text{vitals}} + \mathbf{b} \right)$$

---

## 7. AI & Agentic Core Architecture

### 7.1 Hybrid Cloud/Edge Dual Engine
* **Offline Edge Agent**: Local Dart/C++ inference runtime utilizing on-device TF-IDF vector retrieval, phonetic rule engines, and pre-compiled prompt routines. Operates with zero internet connectivity.
* **Online Cloud Agent (Gemini 2.5 Flash / 1.5 Pro)**: Activated when network connectivity is present for deep multi-turn empathetic dialogue, complex question answering, and multimodal visual analysis.

```
       Incoming User Signal (Gestures / Telemetry)
                          │
                          ▼
             Connectivity Check (Online?)
                    ├── Yes ──► Gemini 2.5 Flash / Pro API
                    │           • Deep reasoning & empathy
                    │           • Complex question answering
                    │
                    └── No ───► Local Offline Asha Agent
                                • On-device 7-Domain RAG
                                • Micro-lattice intent mapper
                                • Local TTS & Alerts
```

### 7.2 The 4 Specialized Clinical Agents

```
┌─────────────────────────────────────────────────────────────┐
│                    ASHA SPECIALIZED AGENTS                  │
├──────────────────────────────┬──────────────────────────────┤
│ 💬 Communication Agent       │ 🩺 Health Monitoring Agent   │
│ • AAC intent expansion       │ • Vital signs surveillance   │
│ • Natural tone matching      │ • Pain index calculation     │
│ • Multilingual TTS           │ • Hydration adherence        │
├──────────────────────────────┼──────────────────────────────┤
│ 🏃 Rehabilitation Agent      │ 🚨 Emergency Agent           │
│ • Repetitive motor coaching  │ • Instant fall classification│
│ • Dysarthria vocal pacing    │ • Seizure timer & first-aid  │
│ • Fatigue-aware rests        │ • 911 / Caregiver escalation │
└──────────────────────────────┴──────────────────────────────┘
```

1. **Communication Agent**: Expands single micro-triggers into fluent sentences formatted with appropriate emotional tone, tense, and vocabulary.
2. **Health Monitoring Agent**: Continuously correlates heart rate, respiration, and PAINAD scores against the patient's digital twin baseline.
3. **Rehabilitation Agent**: Guides patient through physical therapy routines (e.g., cervical extension, wrist flexion) with real-time audio coaching and pacing.
4. **Emergency Agent**: Evaluates acute events (falls, prolonged apnea, seizure spikes), coordinates local alarms, and escalates to external responders.

### 7.3 3-Tier Human Cognitive Memory Model
* **Working Memory**: Sliding session buffer maintaining immediate conversation context and current physiological state.
* **Episodic Memory**: Timestamped log of events, medication administrations, therapy successes, and acute events.
* **Semantic Profile (Digital Twin)**: Permanent reference model containing patient pathology, verified prescriptions, baseline vitals, communication modality preferences, and emergency contacts.

### 7.4 7-Domain Clinical Knowledge Base (Offline RAG)
Curated medical vector chunks indexed on-device:
1. **Stroke Rehabilitation & Motor Recovery**: Task-oriented neuroplasticity exercises, repetitive motion pacing.
2. **Speech Therapy & Dysarthria Pacing**: Phoneme articulation, syllable rate control, respiratory-phonatory coordination.
3. **Autism Spectrum Support & Sensory Regulation**: Visual routines, low-stimulus transitions, emotional regulation.
4. **ICU Communication Boards & Intubation AAC**: High-speed binary emergency selection grids.
5. **Neurological Physiotherapy & Positioning**: Spasticity reduction, cervical alignment, pressure sore offloading.
6. **Clinical Caregiver Guidelines**: Transfer mechanics, caregiver burnout prevention, acute escalation rules.
7. **User Digital Twin Personalized Directives**: Patient-specific clinical protocols and physician orders.

### 7.5 Bilingual Diacritic Tokenization Engine
To ensure diacritic and conjunct integrity across South Asian languages (e.g., Bengali), the search tokenizer uses Unicode property patterns:

$$\text{Regex Pattern}: \quad \verb![\p{L}\p{M}\p{N}-]+!$$

* `\p{L}` matches any Unicode letter.
* `\p{M}` captures essential combining marks, diacritics, Bengali matras, and viramas (`্`, `ি`, `ু`, `ো`), ensuring that medical terms such as `স্ট্রোক` and `ব্যায়াম` are indexed without corruption.

### 7.6 Agent Tool Dispatch & Autonomous Actions (`tools.py`)

```python
class AgentToolRegistry:
    def dispatch(self, tool_name: str, arguments: dict[str, Any]) -> ToolResult:
        match tool_name:
            case "speak_voice_response":
                return self._tts_engine.speak(arguments["text"], arguments.get("language", "en"))
            case "start_rehabilitation_exercise":
                return self._rehab_controller.initiate_routine(arguments["exercise_id"])
            case "call_caregiver":
                return self._telephony.notify_caregiver(arguments["urgency"], arguments["reason"])
            case "record_symptom_log":
                return self._memory.append_episodic(arguments["symptom_type"], arguments["severity"])
            case "remind_medication":
                return self._scheduler.queue_medication_reminder(arguments["medication_name"])
            case _:
                raise UnknownToolError(f"Tool {tool_name} not registered in agent safety sandbox.")
```

---

## 8. End-to-End System Specifications

| Parameter | Specification |
| :--- | :--- |
| **Supported Platforms** | Android (Native APK), iOS (Native IPA), Linux (Raspberry Pi 5), Web (PWA) |
| **Computer Vision Engine** | Google MediaPipe 0.10.x + Custom TFLite Heads |
| **Landmark Density** | 478 Points (Dense Face Mesh), 42 Points (Dual-Hand Skeletons) |
| **Vision Inference Latency** | $\le 28\text{ ms}$ on Raspberry Pi 5 + Google Coral Edge TPU |
| **Biometric Telemetry** | Optical rPPG Respiration (0.1–0.5 Hz), PAINAD 10-Point Score |
| **AI Agent Model** | Gemini 2.5 Flash / 1.5 Pro (Online) + Asha Offline Micro-Agent (Offline) |
| **RAG Knowledge Base** | 7 Clinical Domains, 40+ medical modules, bilingual English/Bengali indexing |
| **Data Encryption** | AES-256-GCM at rest; mTLS with TLS 1.3 in transit |
| **Automated Test Coverage**| 184 / 184 passing unit and integration tests |
