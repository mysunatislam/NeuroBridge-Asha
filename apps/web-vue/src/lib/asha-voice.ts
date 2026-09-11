import type { AshaLanguage, VoiceGender } from "../stores/copilot";

const FEMALE_HINTS = [
  "nabanita", "tanishaa", "samantha", "zira", "aria", "jenny", "ava", "emma", "serena",
  "victoria", "karen", "moira", "joanna", "salli", "ivy", "kendra", "kimberly", "amy",
  "nicole", "raveena", "heera", "veena", "susan", "hazel", "sonia", "natasha", "female",
];
const MALE_HINTS = [
  "pradeep", "bashkar", "david", "mark", "george", "daniel", "guy", "ryan", "male", "ravi",
  "matthew", "james", "brian", "aaron",
];

function nameScore(name: string, gender: VoiceGender): number {
  const lower = name.toLowerCase();
  if (lower.includes("samantha")) return 100;
  const preferred = gender === "Female" ? FEMALE_HINTS : MALE_HINTS;
  const opposite = gender === "Female" ? MALE_HINTS : FEMALE_HINTS;
  let score = 0;
  if (preferred.some((hint) => lower.includes(hint))) score += 55;
  if (opposite.some((hint) => lower.includes(hint))) score -= 55;
  if (lower.includes("natural") || lower.includes("neural") || lower.includes("premium")) score += 8;
  return score;
}

function languagePrefix(language: AshaLanguage): "bn" | "en" {
  return language === "Bangla" ? "bn" : "en";
}

export function hasAshaLanguageVoice(language: AshaLanguage): boolean {
  if (!("speechSynthesis" in window)) return false;
  const target = languagePrefix(language);
  return window.speechSynthesis.getVoices().some((voice) => voice.lang.toLowerCase().startsWith(target));
}

export function prepareAshaVoices(): void {
  if ("speechSynthesis" in window) window.speechSynthesis.getVoices();
}

export function chooseAshaVoice(language: AshaLanguage, gender: VoiceGender): SpeechSynthesisVoice | undefined {
  if (!("speechSynthesis" in window)) return undefined;
  const target = languagePrefix(language);
  const matching = window.speechSynthesis.getVoices().filter((voice) => voice.lang.toLowerCase().startsWith(target));
  if (!matching.length) return undefined;

  return [...matching].sort((a, b) => {
    const score = (voice: SpeechSynthesisVoice) => {
      const lang = voice.lang.toLowerCase();
      let result = nameScore(voice.name, gender);
      if (language === "Bangla" && lang.startsWith("bn-bd")) result += 25;
      if (language === "English" && lang.startsWith("en-us")) result += 10;
      if (voice.localService) result += 4;
      return result;
    };
    return score(b) - score(a);
  })[0];
}

export function speakAsha(text: string, options: {
  language: AshaLanguage;
  gender: VoiceGender;
  speed?: "Slow" | "Normal" | "Fast" | string;
  style?: string;
  cancel?: boolean;
}): SpeechSynthesisUtterance | null {
  if (!("speechSynthesis" in window) || !text.trim()) return null;
  if (options.cancel !== false) window.speechSynthesis.cancel();

  const utterance = new SpeechSynthesisUtterance(text);
  utterance.lang = options.language === "Bangla" ? "bn-BD" : "en-US";
  utterance.rate = options.speed === "Slow" ? 0.80 : options.speed === "Fast" ? 1.20 : 1.00;
  const styleOffset = options.style === "Bright" ? .05 : options.style === "Natural" ? -.02 : 0;
  utterance.pitch = 1.00 + styleOffset;

  // Only pin a voice when it actually matches the selected language.
  // If a device has no explicit Bengali voice, leaving voice unset lets the
  // browser/OS route bn-BD to its best available language fallback.
  const voice = chooseAshaVoice(options.language, options.gender);
  if (voice) utterance.voice = voice;

  window.speechSynthesis.speak(utterance);
  return utterance;
}
