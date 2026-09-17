export type OfflineCompanionResponse = {
  reply: string;
  urgent: boolean;
};

const URGENT_LANGUAGE = /\b(emergency|help now|urgent|cannot breathe|can't breathe|chest pain|in danger)\b/i;

export function offlineCompanionReply(message: string): OfflineCompanionResponse {
  const lower = message.toLowerCase().trim();
  const urgent = URGENT_LANGUAGE.test(message);
  if (urgent) {
    return {
      reply: "I could not reach the online Asha service. If you need immediate help, use the Need help button below to send a confirmed alert, or call your caregiver.",
      urgent: true,
    };
  }
  if (lower === "yes" || lower === "yes." || lower === "হাঁ" || lower === "হ্যাঁ") {
    return {
      reply: "Understood clearly. Take your time, I am right here with you.",
      urgent: false,
    };
  }
  if (lower === "no" || lower === "no." || lower === "না") {
    return {
      reply: "I hear you, no problem at all. Rest comfortably.",
      urgent: false,
    };
  }
  if (/\b(water|drink|thirst|thirsty|পানি|জল)\b/i.test(message)) {
    return {
      reply: "I have recorded your hydration request for water. For safe swallowing, remember to stay upright and keep your chin slightly tucked.",
      urgent: false,
    };
  }
  if (/\b(spasm|stiff|spasticity|twitch|cramp)\b/i.test(message)) {
    return {
      reply: "Muscle stiffness or spasticity occurs when upper motor neuron changes remove natural inhibitory signals to spinal reflex arcs (WHY). Gentle, slow range-of-motion stretches and warmth can help soothe the tension (HOW).",
      urgent: false,
    };
  }
  if (/\b(fatigue|tired|exhausted|rest|sleep)\b/i.test(message)) {
    return {
      reply: "I hear you. Communicating via intentional physical gestures takes immense willpower and stamina. Take all the time you need to rest your muscles; I am right here listening.",
      urgent: false,
    };
  }
  if (/\b(alone|afraid|scared|anxious|worried|ভয়)\b/i.test(message)) {
    return {
      reply: "I’m still here with you. Take a slow, gentle breath. You are safe, and your local phrases, Pi display, and caregiver controls are always ready.",
      urgent: false,
    };
  }
  return {
    reply: "I’m here with you. I am monitoring your gestures and choices. You can request water, practice gentle exercises, write to the Pi display, or call your caregiver anytime.",
    urgent: false,
  };
}

/** Keeps only characters accepted by a tel: handoff; it never supplies a number. */
export function dialablePhone(value: string): string {
  const trimmed = value.trim();
  const prefix = trimmed.startsWith("+") ? "+" : "";
  const digits = trimmed.replace(/\D/g, "").slice(0, 20);
  return digits ? `${prefix}${digits}` : "";
}
