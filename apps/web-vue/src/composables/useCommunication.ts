import { ref } from "vue";
import type { Gesture } from "../lib/fingerspeak";
import { useFingerSpeakStore, type SpokenEntry } from "../stores/fingerspeak";
import { useCopilotStore } from "../stores/copilot";
import { speakAsha } from "../lib/asha-voice";

const BANGLA_GESTURE_PHRASES: Record<string, string> = {
  yes: "হ্যাঁ।",
  no: "না।",
  water: "আমার পানি দরকার, অনুগ্রহ করে।",
  nurse: "নার্সকে ডাকুন, অনুগ্রহ করে।",
  emergency: "এটি জরুরি অবস্থা। আমার এখনই সাহায্য দরকার।",
};

export function useCommunication() {
  const store = useFingerSpeakStore();
  const copilot = useCopilotStore();
  const voiceMessage = ref("Ready to speak.");
  const armedGestureId = ref<string | null>(null);
  let armedTimer: number | null = null;

  function makeUtterance(text: string): SpeechSynthesisUtterance | null {
    return speakAsha(text, {
      language: copilot.language,
      gender: copilot.voiceGender,
      speed: copilot.speakingSpeed,
      style: copilot.preferredVoice,
    });
  }

  function speakGesture(gesture: Gesture, source: SpokenEntry["source"]): void {
    if (!gesture.phrase) return;
    const spokenGesture = copilot.language === "Bangla" && BANGLA_GESTURE_PHRASES[gesture.id]
      ? { ...gesture, phrase: BANGLA_GESTURE_PHRASES[gesture.id] }
      : gesture;
    store.logSpoken(spokenGesture, source);
    const utterance = makeUtterance(spokenGesture.phrase);
    if (!utterance) {
      voiceMessage.value = "Speech is unavailable. Keep the caption visible and use a backup AAC method.";
      if (spokenGesture.risk !== "routine") void store.queueEvent(spokenGesture, "caregiver_alert");
      return;
    }
    utterance.onend = () => {
      voiceMessage.value = copilot.language === "Bangla" ? `বলা হয়েছে: “${spokenGesture.phrase}”` : `Spoken: “${spokenGesture.phrase}”`;
      void store.queueEvent(gesture, "phrase_spoken");
    };
    utterance.onerror = () => { voiceMessage.value = "Voice output failed. Keep the caption visible and use the backup call control if urgent."; };
    if (spokenGesture.risk !== "routine") void store.queueEvent(spokenGesture, "caregiver_alert");
  }

  function speakPhrase(phrase: string): void {
    const clean = phrase.trim();
    if (!clean) return;
    const customGesture: Gesture = { id: "patient-composed", name: "Composed phrase", phrase: clean, icon: "✦", risk: "routine", dwellMs: 650, samples: [] };
    store.logSpoken(customGesture, "touch");
    const utterance = makeUtterance(clean);
    if (!utterance) {
      voiceMessage.value = "Speech is unavailable. Keep the composed phrase visible and use a backup AAC method.";
      return;
    }
    utterance.onend = () => { voiceMessage.value = `Spoken: “${clean}”`; };
    utterance.onerror = () => { voiceMessage.value = "Voice output failed. Keep the composed phrase visible and use a backup communication method."; };
  }

  function touchPhrase(gesture: Gesture): void {
    if (gesture.risk === "emergency" && armedGestureId.value !== gesture.id) {
      armedGestureId.value = gesture.id;
      voiceMessage.value = "Emergency phrase armed. Touch it again within three seconds to confirm.";
      if (armedTimer !== null) window.clearTimeout(armedTimer);
      armedTimer = window.setTimeout(() => { armedGestureId.value = null; }, 3_000);
      return;
    }
    armedGestureId.value = null;
    speakGesture(gesture, "touch");
  }

  function dispose(): void {
    if (armedTimer !== null) window.clearTimeout(armedTimer);
    armedTimer = null;
    window.speechSynthesis?.cancel();
  }

  return { voiceMessage, armedGestureId, speakGesture, speakPhrase, touchPhrase, dispose };
}
