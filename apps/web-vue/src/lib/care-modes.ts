import type { CareMode } from "../stores/copilot";

export type ModeConfig = {
  id: CareMode;
  path: string;
  icon: string;
  title: string;
  short: string;
  audience: string;
  voicePrompt: { English: string; Bangla: string };
  hero: string;
  description: string;
  features: Array<{ icon: string; title: string; text: string }>;
  cautions: string[];
  actions: Array<{ label: string; to: string; kind?: "primary" | "secondary" }>;
};

export const CARE_MODES: ModeConfig[] = [
  {
    id: "communication", path: "/care", icon: "🫶", title: "Communication & Care", short: "Impairment, stroke, ICU & older-adult support",
    audience: "For people with limited speech or movement, stroke recovery, ICU communication, assisted living and home care.",
    voicePrompt: {
      English: "Communication and care mode. I can help you communicate with either hand, expressions, head and eye cues, while you remain in control of what is spoken.",
      Bangla: "কমিউনিকেশন ও কেয়ার মোড। দুই হাত, মুখভঙ্গি, মাথা ও চোখের সংকেত দেখে যোগাযোগে সাহায্য করব, তবে কী বলা হবে তা আপনার নিয়ন্ত্রণে থাকবে।",
    },
    hero: "A voice when speech or movement is difficult.",
    description: "Personalized gestures, quick AAC phrases, caregiver handoff and wellbeing observations in one patient-centered workspace.",
    features: [
      { icon: "🖐", title: "Either or both hands", text: "Track left and right hands at the same time while a safety gate confirms only one spoken intent." },
      { icon: "👁", title: "Head & eye cues", text: "Observe head direction, blinks and gaze changes as optional access signals." },
      { icon: "♡", title: "Empathetic check-ins", text: "Asha can notice possible sadness, discomfort or distress and ask a respectful follow-up." },
      { icon: "☎", title: "Trusted contact", text: "Confirmed calls can hand off to the phone dialer on supported mobile devices." },
    ],
    cautions: ["Expression cues are not diagnoses.", "Emergency phrases still require explicit confirmation.", "Keep a backup AAC/call method available."],
    actions: [{ label: "Open communication", to: "/speak", kind: "primary" }, { label: "Calibrate gestures", to: "/calibrate" }, { label: "Caregiver view", to: "/caregiver" }],
  },
  {
    id: "autism", path: "/autism", icon: "🧩", title: "Autism Support", short: "Low-pressure communication & routine support",
    audience: "For autism support centers, classrooms, home routines and people who benefit from predictable, low-demand interaction.",
    voicePrompt: {
      English: "Autism support mode. I can keep prompts short, predictable and gentle, with visual communication, routine transitions and optional voice.",
      Bangla: "অটিজম সাপোর্ট মোড। ছোট, পূর্বানুমানযোগ্য ও কোমল নির্দেশনা, ভিজুয়াল কমিউনিকেশন এবং রুটিন ট্রানজিশনে সাহায্য করতে পারি।",
    },
    hero: "Communication without pressure.",
    description: "A calmer experience for requests, choices, sensory needs and transitions. Voice remains optional and can be repeated on demand.",
    features: [
      { icon: "▦", title: "Predictable choice cards", text: "Keep the same high-value needs in familiar positions to reduce interaction load." },
      { icon: "🔉", title: "Gentle voice prompts", text: "Choose female or male Bangla/English voice and slow the speaking rate." },
      { icon: "◌", title: "Sensory-friendly flow", text: "Use the dark theme, lower visual clutter and step-by-step prompts for transitions." },
      { icon: "🙂", title: "Expression-aware empathy", text: "Asha can offer a check-in when a strong distress-like cue persists, without labeling emotion as fact." },
    ],
    cautions: ["Do not infer intent from facial expression alone.", "Respect non-response and allow extra processing time.", "Customize preferred phrases with the individual and support team."],
    actions: [{ label: "Open supported communication", to: "/speak", kind: "primary" }, { label: "Personalize gestures", to: "/calibrate" }],
  },
  {
    id: "rehab", path: "/rehab", icon: "↔", title: "Rehabilitation Coach", short: "Guided movement, repetition & hydration",
    audience: "For supervised rehabilitation exercises, gentle range-of-motion practice and home exercise reminders.",
    voicePrompt: {
      English: "Rehabilitation mode. I can guide gentle head and upper-body movement with voice, observe direction, count repetitions and remind you to stop if you feel pain or dizziness.",
      Bangla: "রিহ্যাবিলিটেশন মোড। কণ্ঠে ধীরে ধীরে মুভমেন্ট গাইড করব, দিক পর্যবেক্ষণ করব, রিপিটেশন গুনব এবং ব্যথা বা মাথা ঘোরা হলে থামতে বলব।",
    },
    hero: "Asha becomes a gentle movement companion.",
    description: "Voice-led routines can pair with head-direction and hand tracking for simple exercise feedback while keeping clinician-prescribed limits in control.",
    features: [
      { icon: "↔", title: "Directional coaching", text: "Guide right, center and left movement with repeatable voice steps." },
      { icon: "◎", title: "Movement observation", text: "Head direction and hand presence can provide simple completion cues for a routine." },
      { icon: "💧", title: "Hydration reminders", text: "Asha can remind users after a configured interval and reset after confirmation." },
      { icon: "⏸", title: "Stop-first safety", text: "Pain, dizziness or discomfort always overrides the exercise flow." },
    ],
    cautions: ["Not a substitute for a physiotherapist or prescribed exercise plan.", "No automatic range-of-motion diagnosis.", "Stop exercise for pain, dizziness, breathing difficulty or new symptoms."],
    actions: [{ label: "Open Asha exercise coach", to: "/speak", kind: "primary" }, { label: "Set gesture access", to: "/calibrate" }],
  },
  {
    id: "continuous", path: "/continuous", icon: "◉", title: "Continuous Support", short: "Low-response & bedside observation support",
    audience: "For caregiver-supervised use with semi-conscious, minimally responsive or long-duration bedside situations.",
    voicePrompt: {
      English: "Continuous support mode. I can keep watching for hand, head, eye and facial changes and surface them to a caregiver. I am not a medical monitor and I do not diagnose consciousness.",
      Bangla: "কন্টিনিউয়াস সাপোর্ট মোড। হাত, মাথা, চোখ ও মুখের পরিবর্তন পর্যবেক্ষণ করে কেয়ারগিভারকে দেখাতে পারি। আমি মেডিক্যাল মনিটর নই এবং চেতনার অবস্থা নির্ণয় করি না।",
    },
    hero: "Always present, never pretending to be a clinical monitor.",
    description: "A continuous observation interface for small visible responses, with human confirmation and clear separation from medical monitoring.",
    features: [
      { icon: "👀", title: "Eye activity", text: "Track blink, directional gaze and rapid gaze changes as visible observations." },
      { icon: "◒", title: "Head movement", text: "Surface repeated head direction changes or prolonged stillness for caregiver review." },
      { icon: "👐", title: "Two-hand presence", text: "Observe either or both hands and route trained gestures through the confirmation machine." },
      { icon: "♡", title: "Distress cue prompt", text: "Possible discomfort or distress can prompt a human check-in; no automatic medical conclusion is made." },
    ],
    cautions: ["Do not use as a coma/consciousness detector.", "Do not replace bedside observation, alarms or vital-sign monitoring.", "Caregiver confirmation is required before escalation."],
    actions: [{ label: "Open observation workspace", to: "/speak", kind: "primary" }, { label: "Open caregiver view", to: "/caregiver" }],
  },
  {
    id: "wellbeing", path: "/wellbeing", icon: "♡", title: "Emotional & Psychiatric Support", short: "Gentle check-ins, grounding & trusted-contact help",
    audience: "For supportive environments where calm prompts, communication access and trusted-contact escalation are useful.",
    voicePrompt: {
      English: "Emotional support mode. I can offer calm check-ins and help you contact someone you trust. Camera cues are only observations and never a psychiatric diagnosis.",
      Bangla: "ইমোশনাল সাপোর্ট মোড। শান্তভাবে চেক-ইন করতে এবং বিশ্বাসের কাউকে যোগাযোগ করতে সাহায্য করব। ক্যামেরার সংকেত কখনও মানসিক রোগ নির্ণয় নয়।",
    },
    hero: "Empathy that asks instead of assuming.",
    description: "Asha responds to confirmed needs, offers grounding-style prompts and can surface possible distress cues with respectful language.",
    features: [
      { icon: "♡", title: "Consent-first check-ins", text: "Asha asks whether support is wanted instead of declaring what someone feels." },
      { icon: "☎", title: "Trusted-person contact", text: "A confirmed action can open the mobile dialer for a stored trusted contact." },
      { icon: "🔊", title: "Voice companionship", text: "Female or male voice, Bangla or English, with adjustable pace." },
      { icon: "◌", title: "Low-pressure grounding", text: "Simple breathing, hydration and one-step prompts can be offered without forcing interaction." },
    ],
    cautions: ["No psychiatric diagnosis from camera cues.", "No automatic emergency call based on emotion inference.", "Use established clinical/crisis pathways when professional help is needed."],
    actions: [{ label: "Open support workspace", to: "/speak", kind: "primary" }, { label: "Caregiver / support view", to: "/caregiver" }],
  },
];

export function modeById(id: CareMode): ModeConfig { return CARE_MODES.find((mode) => mode.id === id) ?? CARE_MODES[0]; }
