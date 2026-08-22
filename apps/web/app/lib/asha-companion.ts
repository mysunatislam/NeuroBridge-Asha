export type OfflineCompanionResponse = {
  reply: string;
  urgent: boolean;
};

const URGENT_LANGUAGE = /\b(emergency|help now|urgent|cannot breathe|can't breathe|chest pain|in danger)\b/i;

export function offlineCompanionReply(message: string): OfflineCompanionResponse {
  const urgent = URGENT_LANGUAGE.test(message);
  if (urgent) {
    return {
      reply: "I could not reach the online Asha service. If you need immediate help, use the Need help button below to send a confirmed alert, or call your caregiver.",
      urgent: true,
    };
  }
  if (/\b(alone|afraid|scared|anxious|worried)\b/i.test(message)) {
    return {
      reply: "I’m still here with you. The online companion is unavailable, but your local phrases, Pi display, and caregiver call controls still work.",
      urgent: false,
    };
  }
  return {
    reply: "I’m here with you. I cannot reach the online companion right now, but you can keep using local phrases, write to the Pi display, or call your caregiver.",
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
