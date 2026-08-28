import {
  DEFAULT_FACE_INTENT_RULES,
  FACE_INTENT_IDS,
  FaceIntentEngine,
  type FaceIntentId,
  type FaceNeutralBaseline,
} from "./face-intent";
import type { Gesture } from "./fingerspeak";

const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$/;

export type FaceControlSettings = {
  id: string;
  profileId: string;
  enabled: boolean;
  baseline: FaceNeutralBaseline | null;
  bindings: Record<FaceIntentId, string | null>;
  updatedAt: string;
};

export const FACE_INTENT_LABELS: Record<FaceIntentId, string> = Object.freeze({
  blink: "Deliberate blink",
  "eyes-left": "Look left",
  "eyes-right": "Look right",
  "brows-up": "Raise eyebrows",
  "mouth-open": "Open mouth",
});

export function faceControlSettingsId(profileId: string): string {
  return `face-controls:${requireId(profileId, "profile id")}`;
}

export function createDefaultFaceControlSettings(
  profileId: string,
  now = new Date(),
): FaceControlSettings {
  requireId(profileId, "profile id");
  return {
    id: faceControlSettingsId(profileId),
    profileId,
    enabled: true,
    baseline: null,
    bindings: {
      blink: "yes",
      "eyes-left": "no",
      "eyes-right": "water",
      "brows-up": "nurse",
      "mouth-open": "emergency",
    },
    updatedAt: now.toISOString(),
  };
}

export function validateFaceControlSettings(value: FaceControlSettings): FaceControlSettings {
  const settings = structuredClone(value);
  requireId(settings.profileId, "profile id");
  if (settings.id !== faceControlSettingsId(settings.profileId)) {
    throw new Error("Face-control settings do not match the profile.");
  }
  if (typeof settings.enabled !== "boolean") throw new Error("Face controls must be enabled or disabled.");
  if (!settings.bindings || typeof settings.bindings !== "object") throw new Error("Face-control bindings are missing.");
  for (const intentId of FACE_INTENT_IDS) {
    const gestureId = settings.bindings[intentId];
    if (gestureId !== null) requireId(gestureId, `${intentId} gesture id`);
  }
  if (settings.baseline) {
    // Construction performs the engine's complete baseline validation.
    new FaceIntentEngine(settings.baseline);
  }
  if (!Number.isFinite(Date.parse(settings.updatedAt))) throw new Error("Face-control timestamp is invalid.");
  return settings;
}

/**
 * Creates a fresh one-shot engine whose hold time can never be shorter than
 * the mapped phrase's safety dwell. Recreate it whenever bindings or gesture
 * safety policy changes so an emergency phrase cannot inherit a routine hold.
 */
export function createFaceControlEngine(
  settings: FaceControlSettings,
  gestures: ReadonlyArray<Gesture>,
): FaceIntentEngine {
  const gestureById = new Map(gestures.map((gesture) => [gesture.id, gesture]));
  const rules = Object.fromEntries(FACE_INTENT_IDS.map((intentId) => {
    const gestureId = settings.bindings[intentId];
    const gesture = gestureId === null ? null : gestureById.get(gestureId) ?? null;
    return [intentId, {
      enabled: settings.enabled && Boolean(gesture?.phrase),
      holdMs: Math.max(DEFAULT_FACE_INTENT_RULES[intentId].holdMs, gesture?.dwellMs ?? 0),
    }];
  }));
  return new FaceIntentEngine(settings.baseline, { rules });
}

function requireId(value: string, label: string): string {
  if (typeof value !== "string" || !SAFE_ID.test(value)) throw new Error(`${label} is invalid.`);
  return value;
}
