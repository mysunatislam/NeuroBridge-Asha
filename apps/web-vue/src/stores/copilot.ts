import { computed, ref, watch } from "vue";
import { defineStore } from "pinia";

export type CommunicationContext = "Hospital" | "Home" | "Classroom" | "Work" | "Social" | "Custom";
export type AshaLanguage = "English" | "Bangla";
export type VoiceGender = "Female" | "Male";
export type ThemeMode = "light" | "dark";
export type CareMode = "communication" | "autism" | "rehab" | "continuous" | "wellbeing";
export type WellbeingCue = "smile" | "sad" | "pain" | "crying" | "neutral";

const CONTEXT_SUGGESTIONS: Record<CommunicationContext, Record<AshaLanguage, string[]>> = {
  Hospital: { English: ["I'm uncomfortable.", "Please adjust my pillow.", "I need a break.", "Could you call the nurse, please?"], Bangla: ["আমার অস্বস্তি লাগছে।", "আমার বালিশটা একটু ঠিক করে দিন।", "আমার একটু বিরতি দরকার।", "নার্সকে একটু ডাকবেন?"] },
  Home: { English: ["Can you turn on the TV?", "I'd like some water, please.", "Could you help me sit up?", "Thank you."], Bangla: ["টিভিটা চালু করে দেবেন?", "আমার একটু পানি দরকার।", "আমাকে একটু উঠে বসতে সাহায্য করবেন?", "ধন্যবাদ।"] },
  Classroom: { English: ["I have a question.", "Could you repeat that, please?", "I need a short break.", "Thank you."], Bangla: ["আমার একটি প্রশ্ন আছে।", "আরেকবার বলবেন?", "আমার একটু বিরতি দরকার।", "ধন্যবাদ।"] },
  Work: { English: ["I have something to add.", "Could you give me a moment?", "Please send that to me.", "Thank you."], Bangla: ["আমি কিছু যোগ করতে চাই।", "আমাকে একটু সময় দেবেন?", "ওটা আমাকে পাঠাবেন, অনুগ্রহ করে।", "ধন্যবাদ।"] },
  Social: { English: ["It's good to see you.", "Tell me more.", "I need a moment, please.", "Thank you."], Bangla: ["তোমাকে দেখে ভালো লাগছে।", "আরও বলো।", "আমাকে একটু সময় দাও।", "ধন্যবাদ।"] },
  Custom: { English: ["I need some help, please.", "Could you give me a moment?", "Yes, please.", "No, thank you."], Bangla: ["আমার একটু সাহায্য দরকার।", "আমাকে একটু সময় দেবেন?", "হ্যাঁ, অনুগ্রহ করে।", "না, ধন্যবাদ।"] },
};
const NEXT_WORDS: Record<CommunicationContext, Record<AshaLanguage, string[]>> = {
  Hospital: { English: ["water", "the nurse", "to rest", "my family"], Bangla: ["পানি", "নার্সকে", "বিশ্রাম", "আমার পরিবারকে"] },
  Home: { English: ["water", "the TV", "to rest", "some help"], Bangla: ["পানি", "টিভি", "বিশ্রাম", "সাহায্য"] },
  Classroom: { English: ["a question", "a break", "more time", "help"], Bangla: ["একটি প্রশ্ন", "বিরতি", "আরও সময়", "সাহায্য"] },
  Work: { English: ["a moment", "to respond", "that file", "help"], Bangla: ["একটু সময়", "উত্তর দিতে", "ওই ফাইলটি", "সাহায্য"] },
  Social: { English: ["to talk", "a break", "water", "to go home"], Bangla: ["কথা বলতে", "বিরতি", "পানি", "বাড়ি যেতে"] },
  Custom: { English: ["water", "help", "a break", "more time"], Bangla: ["পানি", "সাহায্য", "বিরতি", "আরও সময়"] },
};

export const useCopilotStore = defineStore("copilot", () => {
  const context = ref<CommunicationContext>((localStorage.getItem("fingerspeak:context") as CommunicationContext) || "Hospital");
  const composer = ref("I need");
  const preferredVoice = ref("Gentle");
  const voiceGender = ref<VoiceGender>((localStorage.getItem("fingerspeak:voiceGender") as VoiceGender) || "Female");
  const speakingSpeed = ref("Normal");
  const language = ref<AshaLanguage>((localStorage.getItem("fingerspeak:language") as AshaLanguage) || "English");
  const theme = ref<ThemeMode>((localStorage.getItem("fingerspeak:theme") as ThemeMode) || "dark");
  const careMode = ref<CareMode>((localStorage.getItem("fingerspeak:careMode") as CareMode) || "communication");
  const dominantHand = ref("Either");
  const gestureSensitivity = ref("Balanced");
  const savedPhrases = ref<string[]>([]);
  const pendingPhrase = ref<string | null>(null);
  const composerFocusToken = ref(0);
  const wellbeingCue = ref<WellbeingCue>("neutral");
  const trustedContactName = ref("Trusted contact");
  const trustedContactPhone = ref("");

  const suggestions = computed(() => Array.from(new Set([...savedPhrases.value, ...CONTEXT_SUGGESTIONS[context.value][language.value]])).slice(0, 6));
  const nextWords = computed(() => NEXT_WORDS[context.value][language.value]);
  const routineHint = computed(() => language.value === "Bangla"
    ? (context.value === "Hospital" ? "কেয়ার সেশনে পানি ও সাহায্যের বাক্যগুলো এক ট্যাপে রাখুন।" : `${context.value} পরিস্থিতিতে সবচেয়ে ব্যবহৃত বাক্যগুলো সামনে রাখা যায়।`)
    : (context.value === "Hospital" ? "Keep water and help phrases one tap away during a care session." : `Your ${context.value.toLowerCase()} phrases can move forward based on what you use most.`));

  function requestSpeak(phrase: string): void { pendingPhrase.value = phrase.trim(); }
  function clearPendingPhrase(): void { pendingPhrase.value = null; }
  function setComposerPhrase(phrase: string): void { composer.value = phrase.replace(/[.!?।]+$/, ""); composerFocusToken.value += 1; }
  function appendWord(word: string): void { composer.value = `${composer.value.trim()} ${word}`.replace(/\s+/g, " ").trim(); }
  function resetComposer(): void { composer.value = language.value === "Bangla" ? "আমার দরকার" : "I need"; }
  function savePhrase(phrase: string): void { const clean = phrase.trim(); if (clean && !savedPhrases.value.includes(clean)) savedPhrases.value = [clean, ...savedPhrases.value].slice(0, 8); }
  function setLanguage(next: AshaLanguage): void { language.value = next; resetComposer(); }
  function toggleTheme(): void { theme.value = theme.value === "dark" ? "light" : "dark"; }
  function setCareMode(next: CareMode): void { careMode.value = next; }

  watch(theme, (value) => { document.documentElement.dataset.theme = value; localStorage.setItem("fingerspeak:theme", value); }, { immediate: true });
  watch(language, (value) => localStorage.setItem("fingerspeak:language", value));
  watch(voiceGender, (value) => localStorage.setItem("fingerspeak:voiceGender", value));
  watch(careMode, (value) => localStorage.setItem("fingerspeak:careMode", value));
  watch(context, (value) => localStorage.setItem("fingerspeak:context", value));

  return {
    context, composer, preferredVoice, voiceGender, speakingSpeed, language, theme, careMode, dominantHand, gestureSensitivity,
    savedPhrases, pendingPhrase, composerFocusToken, wellbeingCue, trustedContactName, trustedContactPhone,
    suggestions, nextWords, routineHint, requestSpeak, clearPendingPhrase, setComposerPhrase, appendWord,
    resetComposer, savePhrase, setLanguage, toggleTheme, setCareMode,
  };
});
