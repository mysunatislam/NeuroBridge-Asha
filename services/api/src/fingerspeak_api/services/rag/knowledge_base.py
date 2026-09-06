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
            "tremor",
            "first aid",
            "post-ictal",
            "airway",
            "recovery position",
            "emergency",
            "choking",
        ),
        summary="Emergency response, airway safety, and triage protocols during and immediately following a seizure.",
        content=(
            "Acute Seizure Response Protocol for Caregivers:\n"
            "1. Immediate Safety First: Ease the person to the floor or flat supported surface. Clear sharp or hard objects. "
            "Place a soft folded towel or cushion beneath the head.\n"
            "2. Lateral Recovery Position: Gently roll the patient onto their side to keep the airway clear and allow saliva "
            "or vomit to drain naturally, preventing asphyxiation.\n"
            "3. What NEVER to do: NEVER place anything inside the patient's mouth (no spoons, fingers, or medication). "
            "NEVER forcibly restrain shaking limbs or hold the patient down.\n"
            "4. Timing & Emergency Thresholds: Note the exact start time. Call Emergency Medical Services (911 / 999 / 112) immediately if: "
            "(a) The active convulsion lasts longer than 5 minutes; (b) A second seizure follows without full consciousness regained; "
            "(c) Breathing is labored or compromised after jerking stops; (d) The seizure occurs in water; (e) Patient is injured or pregnant.\n"
            "5. Post-Ictal Care: Expect confusion, drowsiness, and temporary speech loss for 10-30 minutes. Speak in a quiet, reassuring "
            "voice. Do not offer food or drink until the patient is alert and fully conscious."
        ),
        locale="en-US",
    ),
    KnowledgeDocument(
        id="sci-tetraplegia-01",
        title="Spinal Cord Injury (C1-C5 Tetraplegia) Access & Autonomic Dysreflexia Alert",
        category="spinal_cord_injury",
        keywords=(
            "spinal cord",
            "sci",
            "tetraplegia",
            "quadriplegia",
            "c1",
            "c2",
            "c3",
            "c4",
            "c5",
            "switch",
            "dysreflexia",
            "head tilt",
            "environmental",
        ),
        summary="Switch scanning, head motion controls, and Autonomic Dysreflexia warning indicators for high-level SCI.",
        content=(
            "For individuals with high cervical spinal cord injury (C1-C5 tetraplegia) who lack distal finger dexterity:\n"
            "1. Alternative Modalities: Transition input mode from Hand Studio to Head-Motion/Gaze or Single-Switch Scanning. "
            "A micro-head nod, cheek twitch, or mechanical headrest switch allows full AAC navigation.\n"
            "2. Autonomic Dysreflexia (AD) Critical Safety Alert: In lesions at or above T6, an uninhibited sympathetic response "
            "to painful stimuli below the injury (e.g. full bladder, blocked catheter, bowel impaction, skin pressure) can cause "
            "life-threatening hypertension. Symptoms include sudden pounding headache, profuse sweating above lesion, facial flushing, "
            "and severe goosebumps. Protocol: Immediately sit the patient fully upright (90 degrees), loosen tight clothing or abdominal binders, "
            "check urinary drainage bag/tubing, and summon immediate medical assistance.\n"
            "3. Wheelchair Mount Alignment: Ensure camera and tablet mount are rigidly secured to the wheelchair frame so travel vibrations "
            "do not disrupt computer vision tracking."
        ),
        locale="en-US",
    ),
    KnowledgeDocument(
        id="device-ops-01",
        title="NeuroBridge Wheelchair Mount, Raspberry Pi & Camera Calibration",
        category="device_operations",
        keywords=(
            "raspberry pi",
            "pi",
            "wheelchair",
            "camera",
            "mediapipe",
            "lighting",
            "latency",
            "pairing",
            "wifi",
            "hotspot",
            "mount",
            "battery",
        ),
        summary="Hardware setup, lighting conditions, optimal camera distance, and edge connectivity troubleshooting.",
        content=(
            "Optimizing NeuroBridge Asha Computer Vision & IoT Edge Operations:\n"
            "1. Distance & Framing: The camera should be positioned 40cm to 65cm from the patient's hand or face. The hand should occupy "
            "approximately 25% to 50% of the active video frame for reliable landmark tracking.\n"
            "2. Lighting Conditions: Provide diffuse, front-facing ambient light. Avoid strong backlight (e.g., direct window behind patient) "
            "which causes underexposure and silhouette artifacts where MediaPipe loses finger joint coordinates.\n"
            "3. Raspberry Pi Display Companion: The Pi companion runs a local WebSocket server (port 8765) driving an outward-facing e-Paper "
            "or 7-inch LCD. Ensure both phone and Pi are joined to the same wheelchair local hotspot or ad-hoc WiFi network.\n"
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
)
