<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { useRouter } from "vue-router";
import { storeToRefs } from "pinia";
import { useCopilotStore, type AshaLanguage, type WellbeingCue } from "../stores/copilot";
import { hasAshaLanguageVoice, prepareAshaVoices, speakAsha } from "../lib/asha-voice";

const router = useRouter();
const copilot = useCopilotStore();
const {
  context, suggestions, preferredVoice, voiceGender, speakingSpeed, language, dominantHand, gestureSensitivity,
  routineHint, wellbeingCue, trustedContactName, trustedContactPhone,
} = storeToRefs(copilot);

const open = ref(false);
const panel = ref<"assistant" | "exercise" | "settings">("assistant");
const teaserVisible = ref(true);
const teaserIndex = ref(0);
const callPrompt = ref(false);
const callState = ref<"idle" | "asking" | "calling" | "ready">("idle");
const exerciseRunning = ref(false);
const exerciseIndex = ref(0);
const lastHydrationAt = ref(Date.now());
const clock = ref(Date.now());
const nativeVoiceAvailable = ref(false);
let exerciseTimer: number | null = null;
let teaserTimer: number | null = null;
let hideTeaserTimer: number | null = null;
let clockTimer: number | null = null;

const copy = computed(() => language.value === "Bangla" ? {
  greeting: "আমি আছি—যখন দরকার।",
  intro: "আমি পরামর্শ দেব, কিন্তু কী বলা বা করা হবে—সেটা আপনার সিদ্ধান্ত।",
  calibrate: "ক্যামেরা চালু করে ক্যালিব্রেট করুন",
  calibrateSub: "আপনার হাতের নড়াচড়া শেখাতে",
  need: "এখন আপনার কী দরকার?",
  needSub: "দ্রুত বাক্য ও সহায়তা",
  exercise: "ব্যায়াম সহায়ক",
  exerciseSub: "শুধু কণ্ঠে ধাপে ধাপে গাইড",
  settings: "ভয়েস ও ভাষা",
  settingsSub: "আশাকে আপনার মতো করে নিন",
  suggested: "এখন প্রস্তাব",
  routine: "রুটিন ইন্টেলিজেন্স",
  hydrate: "পানি খেয়েছেন?",
  hydrated: "হ্যাঁ, পানি খেয়েছি",
  wellbeing: "ওয়েলবিইং চেক-ইন",
  callQuestion: "আপনার কি কাউকে কল করতে হবে?",
  yesCall: "হ্যাঁ, কল করুন",
  noThanks: "না, আমি ঠিক আছি",
  exerciseTitle: "আশার মুভমেন্ট কোচ",
  exerciseSafety: "নড়াচড়া খুব কোমল রাখুন। ব্যথা, মাথা ঘোরা বা অস্বস্তি হলে থামুন।",
  start: "শুরু করুন",
  pause: "থামান",
  repeat: "আবার বলুন",
  back: "ফিরুন",
} : {
  greeting: "I’m here whenever you need me.",
  intro: "I can suggest and guide, but you decide what is spoken or acted on.",
  calibrate: "Turn your camera on to calibrate",
  calibrateSub: "Teach FingerSpeak your movement",
  need: "What do you need right now?",
  needSub: "Quick phrases and support",
  exercise: "Exercise assistant",
  exerciseSub: "Voice-only step-by-step coaching",
  settings: "Voice & language",
  settingsSub: "Make Asha feel like yours",
  suggested: "Suggested now",
  routine: "Routine intelligence",
  hydrate: "Have you had water?",
  hydrated: "Yes, I drank water",
  wellbeing: "Wellbeing check-in",
  callQuestion: "Do you need me to call somebody?",
  yesCall: "Yes, call them",
  noThanks: "No, I’m okay",
  exerciseTitle: "Asha movement coach",
  exerciseSafety: "Keep movements gentle. Stop if you feel pain, dizziness, or discomfort.",
  start: "Start routine",
  pause: "Pause",
  repeat: "Say it again",
  back: "Back",
});

const exerciseSteps = computed(() => language.value === "Bangla" ? [
  "ঘাড়ের নড়াচড়া শুরু করুন। ধীরে সামনে তাকান।",
  "এবার ধীরে ডান দিকে ঘোরান। আরামদায়ক সীমা পর্যন্ত।",
  "সামান্য আরও ডানে—শুধু যদি আরাম লাগে।",
  "এখন মাঝখানে ফিরে আসুন।",
  "ধীরে বাম দিকে ঘোরান। আরামদায়ক সীমা পর্যন্ত।",
  "মাঝখানে ফিরে আসুন। এবার আরেকবার করি।",
] : [
  "Start the neck movement now. Look straight ahead and stay relaxed.",
  "Turn slowly to the right, only as far as comfortable.",
  "A little more right, only if it still feels comfortable.",
  "Come back to the center.",
  "Turn slowly to the left, only as far as comfortable.",
  "Return to center. Good. Let’s do it again.",
]);

const teaserLines = computed(() => language.value === "Bangla" ? [
  "ক্যামেরা চালু করে ক্যালিব্রেট করবেন?",
  "এখন আপনার কী দরকার?",
  "আপনার দরকার হলে আমি এখানেই আছি।",
  "এক ঘণ্টা হলে আমি পানির কথা মনে করিয়ে দেব।",
] : [
  "Turn your camera on to calibrate.",
  "What do you need right now?",
  "I’m here with you if you need anything.",
  "I can remind you to drink water after an hour.",
]);

const minutesSinceWater = computed(() => Math.floor((clock.value - lastHydrationAt.value) / 60_000));
const hydrationDue = computed(() => minutesSinceWater.value >= 60);
const voiceStatus = computed(() => {
  if (language.value === "Bangla") return nativeVoiceAvailable.value ? "বাংলা voice · bn-BD ready" : "বাংলা voice · system fallback";
  return nativeVoiceAvailable.value ? "English voice · ready" : "English voice · system fallback";
});

function refreshVoiceAvailability(): void {
  nativeVoiceAvailable.value = hasAshaLanguageVoice(language.value);
}

const hydrationText = computed(() => {
  if (language.value === "Bangla") return hydrationDue.value ? "এক ঘণ্টার বেশি হয়েছে—একটু পানি খেতে পারেন।" : `পরের রিমাইন্ডার ${Math.max(1, 60 - minutesSinceWater.value)} মিনিট পরে।`;
  return hydrationDue.value ? "It has been over an hour. A little water may help." : `Next reminder in ${Math.max(1, 60 - minutesSinceWater.value)} min.`;
});

function speak(text: string): void {
  speakAsha(text, {
    language: language.value,
    gender: voiceGender.value,
    speed: speakingSpeed.value,
    style: preferredVoice.value,
  });
}

function announce(text: string): void {
  teaserVisible.value = true;
  speak(text);
  scheduleHideTeaser();
}

function scheduleHideTeaser(): void {
  if (hideTeaserTimer !== null) window.clearTimeout(hideTeaserTimer);
  hideTeaserTimer = window.setTimeout(() => { if (!open.value) teaserVisible.value = false; }, 6_000);
}

function scheduleNextTeaser(): void {
  if (teaserTimer !== null) window.clearInterval(teaserTimer);
  teaserTimer = window.setInterval(() => {
    if (open.value) return;
    teaserIndex.value = (teaserIndex.value + 1) % teaserLines.value.length;
    teaserVisible.value = true;
    scheduleHideTeaser();
  }, 24_000);
}

async function go(path: string): Promise<void> {
  open.value = false;
  await router.push(path);
}

async function buildSentence(): Promise<void> {
  await router.push("/speak");
  copilot.composerFocusToken += 1;
  open.value = false;
}

function speakSuggested(): void {
  const phrase = suggestions.value[1] ?? suggestions.value[0];
  if (phrase) copilot.requestSpeak(phrase);
}

function setLanguage(next: AshaLanguage): void {
  copilot.setLanguage(next);
  refreshVoiceAvailability();
  announce(next === "Bangla" ? "আমি এখন বাংলায় কথা বলব।" : "I’ll speak in English now.");
}

function changeLanguage(event: Event): void {
  const target = event.target as HTMLSelectElement | null;
  if (target?.value === "English" || target?.value === "Bangla") setLanguage(target.value);
}

let suppressCueVoice = false;
let lastAutoEmpathyAt = 0;

const empathyLines: Record<WellbeingCue, Record<AshaLanguage, string>> = {
  smile: { English: "I noticed a smile. I’m right here if you need anything.", Bangla: "আপনার মুখে হাসি দেখছি। কিছু দরকার হলে আমি আছি।" },
  sad: { English: "You may be feeling low. Would you like me to call someone you trust?", Bangla: "আপনার মন খারাপ হতে পারে। বিশ্বাসের কাউকে কি কল করতে চান?" },
  pain: { English: "I noticed a possible discomfort expression. Are you in pain, or should I call someone?", Bangla: "অস্বস্তির মতো একটি মুখভঙ্গি দেখছি। আপনার কি ব্যথা হচ্ছে, নাকি কাউকে কল করব?" },
  crying: { English: "You may be distressed. I can stay with you and help contact someone if you want.", Bangla: "আপনি হয়তো কষ্টে আছেন। চাইলে আমি পাশে থাকব এবং কাউকে যোগাযোগ করতে সাহায্য করব।" },
  neutral: { English: "I’m here with you if you need anything.", Bangla: "আপনার কিছু দরকার হলে আমি এখানেই আছি।" },
};

function setWellbeing(cue: WellbeingCue): void {
  suppressCueVoice = true;
  wellbeingCue.value = cue;
  suppressCueVoice = false;
  callPrompt.value = cue === "sad" || cue === "pain" || cue === "crying";
  callState.value = callPrompt.value ? "asking" : "idle";
  announce(empathyLines[cue][language.value]);
}

watch(wellbeingCue, (cue, previous) => {
  if (suppressCueVoice || cue === previous) return;
  callPrompt.value = cue === "sad" || cue === "pain" || cue === "crying";
  callState.value = callPrompt.value ? "asking" : "idle";
  if (!(cue === "sad" || cue === "pain" || cue === "crying")) return;
  const now = Date.now();
  if (now - lastAutoEmpathyAt < 25_000) return;
  lastAutoEmpathyAt = now;
  announce(empathyLines[cue][language.value]);
}, { flush: "sync" });

function confirmCall(): void {
  const name = trustedContactName.value.trim() || (language.value === "Bangla" ? "বিশ্বস্ত যোগাযোগ" : "your trusted contact");
  callState.value = "calling";
  const line = language.value === "Bangla" ? `ঠিক আছে, ${name}-কে কল করছি।` : `Okay, calling ${name}.`;
  speak(line);
  window.setTimeout(() => {
    callState.value = "ready";
    const number = trustedContactPhone.value.replace(/[^+\d]/g, "");
    if (number) window.location.href = `tel:${number}`;
  }, 900);
}

function declineCall(): void {
  callPrompt.value = false;
  callState.value = "idle";
  speak(language.value === "Bangla" ? "ঠিক আছে। আমি এখানেই আছি।" : "Okay. I’m right here.");
}

function markHydrated(): void {
  lastHydrationAt.value = Date.now();
  localStorage.setItem("fingerspeak:asha:lastHydrationAt", String(lastHydrationAt.value));
  clock.value = Date.now();
  speak(language.value === "Bangla" ? "দারুণ। আমি এক ঘণ্টা পরে আবার মনে করিয়ে দেব।" : "Great. I’ll remind you again in an hour.");
}

function clearExerciseTimer(): void {
  if (exerciseTimer !== null) window.clearTimeout(exerciseTimer);
  exerciseTimer = null;
}

function runExerciseStep(): void {
  if (!exerciseRunning.value) return;
  const step = exerciseSteps.value[exerciseIndex.value];
  speak(step);
  exerciseTimer = window.setTimeout(() => {
    if (!exerciseRunning.value) return;
    exerciseIndex.value = (exerciseIndex.value + 1) % exerciseSteps.value.length;
    runExerciseStep();
  }, 5_200);
}

function toggleExercise(): void {
  exerciseRunning.value = !exerciseRunning.value;
  clearExerciseTimer();
  if (exerciseRunning.value) runExerciseStep();
  else window.speechSynthesis?.cancel();
}

function repeatExercise(): void { speak(exerciseSteps.value[exerciseIndex.value]); }

watch(hydrationDue, (due) => {
  if (!due) return;
  announce(language.value === "Bangla" ? "আপনি এক ঘণ্টা পানি খাননি। একটু পানি খাবেন?" : "You haven’t had water in an hour. Would you like a drink?");
});

watch(panel, (next) => {
  if (next !== "exercise") {
    exerciseRunning.value = false;
    clearExerciseTimer();
  }
});

onMounted(() => {
  prepareAshaVoices();
  refreshVoiceAvailability();
  window.speechSynthesis?.addEventListener("voiceschanged", refreshVoiceAvailability);
  const saved = Number(localStorage.getItem("fingerspeak:asha:lastHydrationAt"));
  lastHydrationAt.value = Number.isFinite(saved) && saved > 0 ? saved : Date.now();
  clockTimer = window.setInterval(() => { clock.value = Date.now(); }, 30_000);
  scheduleHideTeaser();
  scheduleNextTeaser();
});

onBeforeUnmount(() => {
  window.speechSynthesis?.removeEventListener("voiceschanged", refreshVoiceAvailability);
  clearExerciseTimer();
  if (teaserTimer !== null) window.clearInterval(teaserTimer);
  if (hideTeaserTimer !== null) window.clearTimeout(hideTeaserTimer);
  if (clockTimer !== null) window.clearInterval(clockTimer);
  window.speechSynthesis?.cancel();
});
</script>

<template>
  <div class="asha-root">
    <Transition name="asha-teaser">
      <button v-if="teaserVisible && !open" class="asha-teaser" @click="open = true">
        <span class="teaser-spark">✦</span><span>{{ teaserLines[teaserIndex] }}</span>
      </button>
    </Transition>

    <Transition name="asha-panel">
      <aside v-if="open" class="asha-panel" aria-label="Asha AI assist system">
        <div class="asha-panel-head">
          <div :class="['asha-avatar', `mood-${wellbeingCue}`]">
            <img src="/asha-avatar-face.webp" alt="Asha, FingerSpeak AI assist" />
            <span class="asha-avatar-glow" aria-hidden="true" />
            <em aria-hidden="true">✦</em>
          </div>
          <div><strong>Asha</strong><small>Personal AI assist · always nearby</small></div>
          <button aria-label="Close Asha" @click="open = false">×</button>
        </div>

        <div class="asha-language-toggle" aria-label="Asha language">
          <button :class="{ active: language === 'English' }" @click="setLanguage('English')">EN</button>
          <button :class="{ active: language === 'Bangla' }" @click="setLanguage('Bangla')">বাংলা</button>
          <span><i /> {{ voiceStatus }}</span>
        </div>

        <template v-if="panel === 'assistant'">
          <div class="asha-greeting">
            <small>ASHA · LIVE ASSIST</small><h3>{{ copy.greeting }}</h3><p>{{ copy.intro }}</p>
          </div>

          <div class="asha-actions">
            <button @click="go('/calibrate')"><span>◎</span><div><strong>{{ copy.calibrate }}</strong><small>{{ copy.calibrateSub }}</small></div><b>→</b></button>
            <button @click="buildSentence"><span>✦</span><div><strong>{{ copy.need }}</strong><small>{{ copy.needSub }}</small></div><b>→</b></button>
            <button class="exercise-action" @click="panel = 'exercise'"><span>↔</span><div><strong>{{ copy.exercise }}</strong><small>{{ copy.exerciseSub }}</small></div><b>→</b></button>
            <button @click="panel = 'settings'"><span>◖</span><div><strong>{{ copy.settings }}</strong><small>{{ copy.settingsSub }}</small></div><b>→</b></button>
          </div>

          <div class="asha-suggestion">
            <div><span>✦ {{ copy.suggested }}</span><small>{{ context }}</small></div>
            <button @click="speakSuggested">{{ suggestions[1] ?? suggestions[0] }}</button>
          </div>

          <div class="wellbeing-card">
            <div class="micro-heading"><span>♡</span><strong>{{ copy.wellbeing }}</strong><small>prototype cues · confirm first</small></div>
            <div class="mood-chips">
              <button :class="{ active: wellbeingCue === 'smile' }" @click="setWellbeing('smile')">🙂 <span>Smile</span></button>
              <button :class="{ active: wellbeingCue === 'sad' }" @click="setWellbeing('sad')">😔 <span>Sad</span></button>
              <button :class="{ active: wellbeingCue === 'pain' }" @click="setWellbeing('pain')">😣 <span>Pain</span></button>
              <button :class="{ active: wellbeingCue === 'crying' }" @click="setWellbeing('crying')">😢 <span>Distress</span></button>
              <button :class="{ active: wellbeingCue === 'neutral' }" @click="setWellbeing('neutral')">• <span>Okay</span></button>
            </div>
            <Transition name="call-prompt">
              <div v-if="callPrompt" class="call-confirm">
                <strong>{{ copy.callQuestion }}</strong>
                <div><button class="call-yes" @click="confirmCall">☎ {{ copy.yesCall }}</button><button @click="declineCall">{{ copy.noThanks }}</button></div>
                <small v-if="callState === 'ready' && !trustedContactPhone">Mobile handoff demo: add a trusted number in Settings to open the phone dialer.</small>
              </div>
            </Transition>
          </div>

          <div :class="['hydration-card', { due: hydrationDue }]">
            <span class="water-orb">◒</span>
            <div><strong>{{ copy.hydrate }}</strong><small>{{ hydrationText }}</small></div>
            <button @click="markHydrated">{{ copy.hydrated }}</button>
          </div>

          <div class="routine-intelligence"><span>{{ copy.routine }}</span><p>{{ routineHint }}</p></div>
        </template>

        <template v-else-if="panel === 'exercise'">
          <div class="asha-subhead"><button @click="panel = 'assistant'">←</button><div><small>VOICE-ONLY COACH</small><h3>{{ copy.exerciseTitle }}</h3></div></div>
          <div class="exercise-visual" aria-hidden="true"><span class="neck-head">●</span><i /><b :class="{ moving: exerciseRunning }">↔</b></div>
          <p class="exercise-safety">{{ copy.exerciseSafety }}</p>
          <div class="exercise-current"><small>STEP {{ exerciseIndex + 1 }} / {{ exerciseSteps.length }}</small><strong>{{ exerciseSteps[exerciseIndex] }}</strong></div>
          <div class="exercise-controls"><button class="primary-exercise" @click="toggleExercise">{{ exerciseRunning ? copy.pause : copy.start }}</button><button @click="repeatExercise">↻ {{ copy.repeat }}</button></div>
          <div class="exercise-progress"><i v-for="(_, index) in exerciseSteps" :key="index" :class="{ done: index <= exerciseIndex }" /></div>
        </template>

        <template v-else>
          <div class="asha-subhead"><button @click="panel = 'assistant'">←</button><div><small>MY ASHA</small><h3>Voice, language & trusted contact.</h3></div></div>
          <label class="asha-field">Voice gender<select v-model="voiceGender"><option>Female</option><option>Male</option></select></label>
          <label class="asha-field">Voice style<select v-model="preferredVoice"><option>Gentle</option><option>Bright</option><option>Natural</option></select></label>
          <label class="asha-field">Speaking speed<select v-model="speakingSpeed"><option>Slow</option><option>Normal</option><option>Fast</option></select></label>
          <label class="asha-field">Language<select :value="language" @change="changeLanguage"><option>English</option><option>Bangla</option></select></label>
          <label class="asha-field">Dominant hand<select v-model="dominantHand"><option>Right</option><option>Left</option><option>Either</option></select></label>
          <label class="asha-field">Gesture sensitivity<select v-model="gestureSensitivity"><option>Gentle</option><option>Balanced</option><option>Precise</option></select></label>
          <label class="asha-text-field">Trusted contact name<input v-model="trustedContactName" placeholder="e.g. Family / Caregiver" /></label>
          <label class="asha-text-field">Mobile number<input v-model="trustedContactPhone" inputmode="tel" placeholder="e.g. +8801…" /></label>
          <button class="asha-test-voice" @click="speak(language === 'Bangla' ? 'হ্যালো, আমি আশা। আমি আপনার সাথে আছি।' : 'Hello, I’m Asha. I’m right here with you.')">▶ Test Asha voice</button>
          <p class="asha-local-note">Asha can use either a female or male English/Bangla system voice. Exact voice availability depends on the browser/device. Camera-based wellbeing cues should remain assistive prompts, never diagnoses or automatic emergency decisions.</p>
        </template>
      </aside>
    </Transition>

    <button class="asha-orb" :aria-expanded="open" aria-label="Open Asha AI assist" @click="open = !open">
      <span class="asha-mini-avatar"><img src="/asha-avatar-face.webp" alt="" aria-hidden="true" /><b>✦</b></span>
      <span class="asha-orb-copy"><strong>Asha</strong><small>{{ language === 'Bangla' ? 'আমি আছি' : 'I’m here with you' }}</small></span>
      <span class="asha-live-dot" />
    </button>
  </div>
</template>
