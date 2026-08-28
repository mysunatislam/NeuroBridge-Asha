import type { FaceControlSettings } from "./face-controls";
import type { FaceIntentId } from "./face-intent";
import type { FingerSpeakProfile, Gesture } from "./fingerspeak";
import type { PiPatientIntent, PiPatientIntentName } from "./pi-device";

export const PI_INTENT_MIN_CONFIDENCE = 0.72;
export const PI_EMERGENCY_CONFIRMATION_WINDOW_MS = 10_000;

const FACE_INTENT_BY_PI_INTENT: Record<PiPatientIntentName, FaceIntentId> = Object.freeze({
  blink: "blink",
  look_left: "eyes-left",
  look_right: "eyes-right",
  eyebrows_up: "brows-up",
  mouth_open: "mouth-open",
});

export type PiEmergencyArm = {
  profileId: string;
  gestureId: string;
  phrase: string;
  intent: PiPatientIntentName;
  firstMessageId: string;
  expiresAt: number;
};

export type PiIntentRoute =
  | { action: "ignore"; reason: string; nextEmergencyArm: null }
  | { action: "arm-emergency"; reason: string; nextEmergencyArm: PiEmergencyArm }
  | { action: "speak"; gesture: Gesture; nextEmergencyArm: null };

/**
 * Maps a semantic Pi event only through the active profile's current local face bindings.
 * The Pi sends no phrase, audio, landmarks, frame, or profile data.
 */
export function routePiPatientIntent(
  event: PiPatientIntent,
  profile: FingerSpeakProfile,
  faceControls: FaceControlSettings,
  emergencyArm: PiEmergencyArm | null,
  now = Date.now(),
): PiIntentRoute {
  if (!faceControls.enabled || faceControls.profileId !== profile.id) {
    return { action: "ignore", reason: "Pi face controls are disabled or belong to another profile.", nextEmergencyArm: null };
  }
  if (event.confidence < PI_INTENT_MIN_CONFIDENCE) {
    return { action: "ignore", reason: "Pi movement confidence was below the local safety threshold.", nextEmergencyArm: null };
  }
  const faceIntent = FACE_INTENT_BY_PI_INTENT[event.intent];
  const gestureId = faceControls.bindings[faceIntent];
  if (!gestureId) return { action: "ignore", reason: "This Pi movement has no current patient phrase binding.", nextEmergencyArm: null };
  const gesture = profile.gestures.find((candidate) => candidate.id === gestureId);
  if (!gesture?.phrase) return { action: "ignore", reason: "The current Pi movement binding does not resolve to a spoken phrase.", nextEmergencyArm: null };

  if (gesture.risk !== "emergency") return { action: "speak", gesture, nextEmergencyArm: null };
  const confirmsCurrentArm = emergencyArm
    && emergencyArm.profileId === profile.id
    && emergencyArm.gestureId === gesture.id
    && emergencyArm.phrase === gesture.phrase
    && emergencyArm.intent === event.intent
    && emergencyArm.firstMessageId !== event.messageId
    && emergencyArm.expiresAt >= now;
  if (confirmsCurrentArm) return { action: "speak", gesture, nextEmergencyArm: null };
  return {
    action: "arm-emergency",
    reason: "Emergency phrase armed. Repeat the same deliberate movement once more within ten seconds to speak it.",
    nextEmergencyArm: {
      profileId: profile.id,
      gestureId: gesture.id,
      phrase: gesture.phrase,
      intent: event.intent,
      firstMessageId: event.messageId,
      expiresAt: now + PI_EMERGENCY_CONFIRMATION_WINDOW_MS,
    },
  };
}
