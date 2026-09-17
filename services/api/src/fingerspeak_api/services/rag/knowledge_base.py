"""Curated clinical, assistive AAC, and emergency guidance knowledge base for NeuroBridge Asha."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

KnowledgeCategory = Literal[
    "als_mnd",
    "stroke_aphasia",
    "seizure_first_aid",
    "spinal_cord_injury",
    "device_operations",
    "care_routine",
    "bilingual_guidance",
    "stroke_rehabilitation",
    "speech_therapy",
    "autism_support",
    "icu_communication",
    "physiotherapy",
    "caregiver_guidelines",
    "user_specific_instructions",
]


@dataclass(frozen=True, slots=True)
class KnowledgeDocument:
    id: str
    title: str
    category: KnowledgeCategory
    keywords: tuple[str, ...]
    summary: str
    content: str
    locale: str = "en-US"


CLINICAL_KNOWLEDGE_DOCUMENTS: tuple[KnowledgeDocument, ...] = (
    KnowledgeDocument(
        id="als-mnd-01",
        title="ALS & Motor Neuron Disease AAC Communication & Energy Conservation",
        category="als_mnd",
        keywords=(
            "als",
            "amyotrophic",
            "lateral",
            "sclerosis",
            "mnd",
            "motor neuron",
            "fatigue",
            "bulbar",
            "micro-gesture",
            "dwell",
            "energy",
            "weakness",
            "tremor",
        ),
        summary="Guidance on micro-gestures, pacing, and fatigue management for progressive motor neuron disease.",
        content=(
            "In progressive motor neuron disease (ALS/MND), voluntary motor unit recruitment diminishes, "
            "often leading to rapid muscular fatigue during repeated movements. For patients using micro-gestures:\n"
            "1. Pacing & Dwell: Maintain dwell thresholds between 500ms and 750ms to prevent accidental triggers while "
            "avoiding prolonged isometric contraction that causes rapid tremor or exhaustion.\n"
            "2. Low-Effort Resting States: Calibrate gestures with hand resting comfortably on a tray, armrest, or lap. "
            "Do not require unsupported anti-gravity hand holding.\n"
            "3. Energy Conservation: Schedule frequent low-stimulation rest intervals. If muscular twitching (fasciculations) "
            "or fatigue spikes occur, switch to secondary access modes such as single-switch scanning or eye-gaze blinking.\n"
            "4. Core Essentials: Prioritize urgent phrases ('Water', 'Help', 'Nurse', 'Pain', 'Reposition') at the top of the "
            "vocabulary lattice to minimize physical effort for vital biological needs."
        ),
        locale="en-US",
    ),
    KnowledgeDocument(
        id="stroke-aphasia-01",
        title="Stroke Recovery, Expressive Aphasia & Multi-Modal Communication",
        category="stroke_aphasia",
        keywords=(
            "stroke",
            "aphasia",
            "hemiparesis",
            "expressive",
            "infarct",
            "paralysis",
            "one-handed",
            "confirmation",
            "frustration",
            "speech",
        ),
        summary="Communication scaffolding and confirmation techniques for stroke survivors with hemiparesis or expressive aphasia.",
        content=(
            "Post-stroke patients frequently experience unilateral hemiparesis paired with expressive aphasia. "
            "Effective communication scaffolding requires:\n"
            "1. Single-Hand Unilateral Tracking: Configure NeuroBridge for unilateral dominant or non-paretic hand tracking. "
            "Ensure the unaffected hand has clean visual contrast against clothing or bed linen.\n"
            "2. Binary Confirmation Grids: When word-retrieval difficulty occurs, provide clear binary yes/no confirmation "
            "rather than open-ended queries. Give at least 5-8 seconds processing time before prompting again.\n"
            "3. Emotional Validation: Expressive aphasia frequently triggers profound frustration. Keep Asha's spoken feedback "
            "concise, encouraging, and dignified. Affirm understanding with visual cues on the companion screen.\n"
            "4. Positioning: Support the affected limb in a neutral anatomical position with pillows to prevent subluxation "
            "and spasticity while using the communicative hand."
        ),
        locale="en-US",
    ),
    KnowledgeDocument(
        id="seizure-triage-01",
        title="Clinical Seizure First Aid & Acute Triage Protocol",
        category="seizure_first_aid",
        keywords=(
            "seizure",
            "convulsion",
            "epilepsy",
            "jerking",
            "tonic-clonic",
            "airway",
            "recovery position",
            "emergency",
            "first aid",
            "postictal",
        ),
        summary="Evidence-based acute seizure safety guidelines and emergency alert criteria.",
        content=(
            "Acute Seizure Action Protocol:\n"
            "1. Immediate Safety: Clear hard, sharp, or hot objects from the immediate environment. Cushion the patient's head "
            "with a soft garment or pillow. Loosen tight neckwear.\n"
            "2. Airway & Posture: Do NOT insert any objects, spoons, or fingers into the mouth. Do NOT restrain limbs during rhythmic contractions. "
            "As convulsions subside, immediately roll the patient onto their side into the recovery position to keep airway clear of saliva or vomitus.\n"
            "3. Timing & Emergency Thresholds: Track duration immediately. Dispatch emergency medical services (911 / 999) if:\n"
            "   a. The active convulsion lasts longer than 5 minutes;\n"
            "   b. A second seizure begins before consciousness is fully regained;\n"
            "   c. Breathing difficulty or cyanosis (blue lips) persists after jerking ceases;\n"
            "   d. The patient sustains significant trauma during the event.\n"
            "4. Reassurance: Speak softly and calmly as the patient awakens from the postictal state. State location, caregiver presence, "
            "and safety."
        ),
        locale="en-US",
    ),
    KnowledgeDocument(
        id="sci-dysreflexia-01",
        title="Spinal Cord Injury & Autonomic Dysreflexia Safety",
        category="spinal_cord_injury",
        keywords=(
            "spinal cord",
            "sci",
            "tetraplegia",
            "quadriplegia",
            "autonomic dysreflexia",
            "hypertension",
            "headache",
            "sweating",
            "flushing",
            "catheter",
            "bladder",
        ),
        summary="Clinical identification and urgent counteraction for Autonomic Dysreflexia in T6 or higher SCI.",
        content=(
            "Autonomic Dysreflexia (AD) is an acute medical emergency affecting individuals with spinal cord lesions at or above T6:\n"
            "1. Classic Symptom Triad: Pounding headache, sudden hypertensive spike (systolic > 20-40 mmHg above baseline), profuse sweating "
            "and skin blotching above the injury level, with cold/pale skin below.\n"
            "2. Immediate Postural Action: Sit the patient upright immediately (at 90 degrees) and lower the legs. This initiates orthostatic "
            "pooling of blood to help reduce intracranial pressure. NEVER lay the patient flat.\n"
            "3. Identify Noxious Stimulus: The primary cause (>80%) is bladder distension or catheter kink. Immediately check for catheter bag "
            "kinks, overfilled drainage bags, or blocked tubing. Secondarily inspect bowel impaction, tight clothing, or pressure spots.\n"
            "4. Caregiver Escalation: If blood pressure remains elevated after sitting upright and clearing tubing, notify emergency clinical personnel immediately."
        ),
        locale="en-US",
    ),
    KnowledgeDocument(
        id="device-ops-01",
        title="Wheelchair Raspberry Pi & NoIR Camera System Operations",
        category="device_operations",
        keywords=(
            "raspberry pi",
            "camera",
            "noir",
            "wheelchair",
            "display",
            "caption",
            "battery",
            "calibration",
            "lighting",
            "tethering",
        ),
        summary="Optimal positioning, ambient lighting, and hardware setup for the wheelchair companion system.",
        content=(
            "Wheelchair Companion Hardware Optimization:\n"
            "1. Camera Alignment: Mount the NoIR camera approximately 45-60 cm from the patient's face and lap plane at a 30-degree downward angle. "
            "Ensure the patient's dominant hand rest position remains centered within the 640x480 video frame.\n"
            "2. Lighting Conditions: The NoIR camera utilizes ambient daylight or infrared illumination. Avoid strong backlighting (such as sitting "
            "directly in front of an unshaded window), which casts deep shadows across finger contours and facial landmarks.\n"
            "3. Caption Display: The 7-inch wheelchair display presents confirmed phrases in high-contrast (amber on black or white on deep navy) "
            "with minimum 32pt font for effortless readability by conversational partners standing 1.5 to 2 meters away.\n"
            "4. Battery Conservation: The edge service reports battery status every 30 seconds. When wheelchair or Pi battery drops below 20%, "
            "Asha triggers a low-power prompt to recharge."
        ),
        locale="en-US",
    ),
    KnowledgeDocument(
        id="care-routine-01",
        title="Patient Care Routine, Hydration Scheduling & Pressure Sore Prevention",
        category="care_routine",
        keywords=(
            "routine",
            "hydration",
            "water",
            "repositioning",
            "pressure ulcer",
            "bed sore",
            "medication",
            "caregiver",
            "check-in",
            "comfort",
        ),
        summary="Preventative care schedules, hydration reminders, and clinical repositioning timelines.",
        content=(
            "Standard Assistive Patient Care Guidelines:\n"
            "1. Repositioning Timeline: Immobile or bed-bound patients must undergo weight-shift or complete repositioning at least once every "
            "2 hours (and every 15-30 minutes when seated in a non-tilt wheelchair) to prevent tissue ischemia and pressure ulcers.\n"
            "2. Hydration Pacing: Patients with dysphagia or limited voluntary swallowing should receive small, thickened sips as prescribed, "
            "paced every 45 to 60 minutes while awake. Asha tracks patient hydration requests and alerts if 2.5 hours elapse without fluid intake.\n"
            "3. Caregiver Notification Tiers: Differentiate routine comfort requests ('Blanket', 'Water', 'Itch') from urgent medical concerns "
            "('Cannot breathe', 'Severe pain', 'Choking') so caregivers maintain prompt response vigilance without alarm fatigue.\n"
            "4. Respite Care: Encourage structured caregiver break handoffs. Night mode dims the screen and activates threshold-based ambient monitoring."
        ),
        locale="en-US",
    ),
    KnowledgeDocument(
        id="bilingual-bn-01",
        title="বাংলা নির্দেশিকা: জরুরি সেবা, প্রাথমিক চিকিৎসা ও রোগী পরিচর্যা",
        category="bilingual_guidance",
        keywords=(
            "বাংলা",
            "জরুরি",
            "প্রাথমিক চিকিৎসা",
            "অ্যাম্বুলেন্স",
            "খিঁচুনি",
            "শ্বাসকষ্ট",
            "পানি",
            "কেয়ারগিভার",
            "স্ট্রোক",
        ),
        summary="বাংলায় জরুরি প্রাথমিক চিকিৎসা ও রোগীর যত্ন সংক্রান্ত নির্দেশনাবলী।",
        content=(
            "জরুরি ও রোগী পরিচর্যা সংক্রান্ত বাংলা নির্দেশিকা:\n"
            "১. খিঁচুনি হলে করণীয়: রোগীকে শক্ত বা ধারালো জিনিস থেকে দূরে রাখুন এবং একপাশে কাত করে শোয়ান যাতে শ্বাসপথ পরিষ্কার থাকে। "
            "মুখের ভেতর চামচ, হাত বা কোনো ওষুধ দেবেন না। খিঁচুনি ৫ মিনিটের বেশি স্থায়ী হলে বা বারবার হলে দ্রুত জরুরি অ্যাম্বুলেন্সে যোগাযোগ করুন।\n"
            "২. শ্বাসকষ্ট হলে: রোগীকে সোজা করে বসিয়ে দিন এবং জামাকাপড় ঢিলা করে দিন। অবিলম্বে কেয়ারগিভার বা ডাক্তারকে জানান।\n"
            "৩. স্ট্রোকের লক্ষণ ও সতর্কতা: মুখ একদিকে বেঁকে যাওয়া, এক হাতের দুর্বলতা বা কথা জড়িয়ে যাওয়া স্ট্রোকের প্রধান লক্ষণ। "
            "দেরি না করে দ্রুত হাসপাতালে নিতে হবে।\n"
            "৪. পানি ও খাবার গ্রহণ: রোগীর শোয়া অবস্থায় পানি পান করাবেন না। গলায় খাবার বা পানি আটকে কাশি হলে রোগীকে ঝুঁকিয়ে পিঠে আলতো চাপ দিন।"
        ),
        locale="bn-BD",
    ),
    KnowledgeDocument(
        id="stroke-rehab-01",
        title="Stroke Rehabilitation & Neuroplastic Motor Relearning",
        category="stroke_rehabilitation",
        keywords=(
            "stroke rehabilitation",
            "hemiparesis",
            "motor relearning",
            "neuroplasticity",
            "rehab",
            "exercise",
            "arm recovery",
            "paretic limb",
            "constraint",
            "repetition",
        ),
        summary="Clinical guidelines for stroke motor rehabilitation, neuroplasticity pacing, and bilateral limb guidance.",
        content=(
            "Stroke Motor Recovery & Rehabilitation Principles:\n"
            "1. Repetitive Task-Oriented Training: Neuroplastic cortical reorganization occurs through focused, purposeful repetitions. "
            "Encourage 10 to 15 deliberate reaching or finger flexion movements per session rather than fatigue-inducing bursts.\n"
            "2. Bilateral Arm Training: Mirroring healthy hand movements with the paretic hand stimulates homologous motor cortex networks.\n"
            "3. Gradual Pacing: Stop immediately if joint pain occurs. Compensatory shoulder hiking should be discouraged in favor of neutral alignment.\n"
            "4. Asha Coaching Loop: Asha initiates gentle prompts: 'Let's move your neck slowly. Turn right... Good. Now slightly more... Excellent.'"
        ),
        locale="en-US",
    ),
    KnowledgeDocument(
        id="speech-therapy-01",
        title="Speech Therapy, Dysarthria Pacing & Articulation Exercises",
        category="speech_therapy",
        keywords=(
            "speech therapy",
            "dysarthria",
            "aphasia",
            "articulation",
            "phoneme",
            "pacing",
            "vocal fatigue",
            "speech",
            "voice",
            "swallowing",
        ),
        summary="Evidence-based speech therapy strategies, oral-motor drills, and dysarthria compensatory pacing.",
        content=(
            "Clinical Speech-Language Pathology Guidelines:\n"
            "1. Pacing & Rate Reduction: In flaccid or spastic dysarthria, slowing syllable production improves consonant intelligibility by 40%.\n"
            "2. Phoneme Shaping Drills: Focus on bilabial (/p/, /b/, /m/) and alveolar (/t/, /d/, /n/) sounds with high visual contrast.\n"
            "3. Vocal Fatigue Management: Schedule high-demand conversational exercises after morning rest periods. Provide instant AAC text when vocal cord fatigue sets in.\n"
            "4. Respiratory-Phonatory Coordination: Instruct patient to inhale comfortably through diaphragm before initiating short 2-3 word utterances."
        ),
        locale="en-US",
    ),
    KnowledgeDocument(
        id="autism-support-01",
        title="Autism Spectrum Support, Sensory Regulation & Low-Cognitive AAC",
        category="autism_support",
        keywords=(
            "autism",
            "asd",
            "sensory overload",
            "regulation",
            "visual schedule",
            "low cognitive load",
            "stimming",
            "meltdown",
            "aac",
        ),
        summary="Sensory regulation protocols, predictable visual AAC scheduling, and de-escalation for neurodivergent users.",
        content=(
            "Autism Assistive Support Protocol:\n"
            "1. Sensory Predictability: Minimize sudden audio or visual animations. Use consistent muted colors and predictable screen layouts.\n"
            "2. Visual Scheduling: Provide chronological step-by-step cue cards ('First water, then rest, then exercise') to reduce transition anxiety.\n"
            "3. Overload De-escalation: If rapid involuntary movements or distress signals are detected, reduce companion audio volume, dim lighting, and present calming breathing prompts.\n"
            "4. Communication Respect: Recognize non-speaking does not mean non-understanding. Keep tone respectful, calm, and direct."
        ),
        locale="en-US",
    ),
    KnowledgeDocument(
        id="icu-comm-01",
        title="ICU Communication Boards & Acute Intubation AAC Protocols",
        category="icu_communication",
        keywords=(
            "icu",
            "intensive care",
            "intubation",
            "endotracheal",
            "ventilator",
            "pain scale",
            "eye blink",
            "critical care",
            "non-verbal",
        ),
        summary="Fast-path communication boards, binary eye-blink confirmation, and acute pain scales for intubated patients.",
        content=(
            "Intensive Care Unit (ICU) Communication Standard:\n"
            "1. Binary Eye-Blink Protocol: Two blinks = 'YES', prolonged eye closure (1.5s) = 'NO'. Allows intubated patients to verify biological needs without vocal cords.\n"
            "2. Priority Biological Grid: Immediate 1-tap access to 'Pain', 'Suction airway', 'Reposition bed', 'Cold/Hot', 'Family member'.\n"
            "3. PAINAD / CPOT Non-Verbal Scoring: Asha observes facial muscle furrowing and brow tension to estimate pain score (0 to 10) even when patient cannot speak.\n"
            "4. Nurse Call Integration: Urgent ICU requests trigger immediate dual alerts on both bedside display and nurse station webhook."
        ),
        locale="en-US",
    ),
    KnowledgeDocument(
        id="physiotherapy-01",
        title="Neurological Physiotherapy, Range of Motion & Spasticity Management",
        category="physiotherapy",
        keywords=(
            "physiotherapy",
            "physical therapy",
            "range of motion",
            "spasticity",
            "contracture",
            "neck movement",
            "hand stretch",
            "joint mobility",
        ),
        summary="Bedside and wheelchair range of motion exercises, contracture prevention, and gentle stretching protocols.",
        content=(
            "Assistive Physiotherapy & Movement Guidelines:\n"
            "1. Cervical & Neck Range of Motion: Gentle lateral rotation (ear toward shoulder) held for 5 seconds improves carotid circulation and reduces cervical tension.\n"
            "2. Passive Wrist & Hand Stretching: Slowly extend fingers using opposite hand or armrest wedge to counteract flexor spasticity common in hemiplegia.\n"
            "3. Postural Alignment: Verify wheelchair pelvis position is seated deep against backrest. Avoid sacral sitting which exacerbates spinal deformities.\n"
            "4. Asha Feedback Loop: Track execution smoothness. Provide positive reinforcement: 'Good, you completed 5 gentle repetitions today.'"
        ),
        locale="en-US",
    ),
    KnowledgeDocument(
        id="caregiver-guidelines-01",
        title="Clinical Caregiver Guidelines, Safe Transfers & Burnout Mitigation",
        category="caregiver_guidelines",
        keywords=(
            "caregiver guidelines",
            "transfer safety",
            "body mechanics",
            "pressure relief",
            "burnout",
            "respite",
            "ergonomics",
            "care plan",
        ),
        summary="Ergonomic patient transfer guidelines, pressure relief schedules, and caregiver wellbeing protocols.",
        content=(
            "Clinical Guidelines for Caregivers:\n"
            "1. Transfer Safety: Maintain wide base of support, keep knees bent, and bring patient close to body center of gravity before standing transfer.\n"
            "2. Offloading Routine: Set automated reminder every 2 hours for bedbound patients and every 30 minutes for wheelchair sitting to offload sacrum and ischial tuberosities.\n"
            "3. Notification Triage: Use Asha's green/yellow/red priority triage to address critical needs without experiencing constant alarm anxiety.\n"
            "4. Caregiver Self-Care: Ensure regular respite breaks and sleep rotation to prevent chronic physical strain and empathetic exhaustion."
        ),
        locale="en-US",
    ),
    KnowledgeDocument(
        id="user-specific-instructions-01",
        title="Patient Digital Twin Personalized Care Directives (Rahim Profile)",
        category="user_specific_instructions",
        keywords=(
            "user specific",
            "digital twin",
            "rahim",
            "profile",
            "preference",
            "bangla",
            "hydration schedule",
            "call daughter",
            "emergency contacts",
        ),
        summary="User Digital Twin profile parameters, personal communication preferences, and individualized routines.",
        content=(
            "Personalized Digital Twin Care Directives:\n"
            "1. Patient Profile: Rahim, 64 years old, recovering from ischemic stroke with right-sided partial motor recovery.\n"
            "2. Preferred Communication: Right hand micro-gestures and eye-blink scanning. Primary language: Bangla, secondary: English.\n"
            "3. Core Routine Requests: Morning water (room temperature), pain relief check at 2 PM, evening video call with daughter (Fatima).\n"
            "4. Active Safety Flags: Fall detection enabled on wheelchair accelerometer. Dysphagia aspiration precautions active (thickened liquids only).\n"
            "5. Prescribed Exercises: Daily 10-minute neck lateral stretches and right-hand finger extension drills guided by Asha."
        ),
        locale="en-US",
    ),
)
