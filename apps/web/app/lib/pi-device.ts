export type PiCameraState = "ready" | "off" | "error" | "unknown";

export type PiTelemetry = {
  caption: string;
  tracking: boolean | null;
  camera: PiCameraState;
  phoneConnected: boolean | null;
  piPowerPercent: number | null;
  wheelchairBatteryPercent: number | null;
  lastSeen: string | null;
};

export type PiCredentialKind = "pairing_code" | "device_credential";

export type PairingAuthenticated = {
  deviceCredential: string | null;
  heartbeatIntervalSeconds: number;
};

export type PiCommandResult = {
  commandId: string;
  commandType: "heartbeat" | "status.get" | "caption.set" | "emergency.display" | "unknown";
  accepted: boolean;
  detail: string;
};

export const PI_PATIENT_INTENTS = ["blink", "look_left", "look_right", "eyebrows_up", "mouth_open"] as const;
export type PiPatientIntentName = (typeof PI_PATIENT_INTENTS)[number];
export type PiPatientIntent = {
  messageId: string;
  deviceId: string;
  sequence: number;
  sentAt: string;
  intent: PiPatientIntentName;
  confidence: number;
  detectedAt: string;
};

export const PI_INTENT_COOLDOWN_MS = 1_200;
export const PI_INTENT_MAX_AGE_MS = 30_000;
const PI_INTENT_MAX_FUTURE_SKEW_MS = 5_000;
const PI_INTENT_MAX_DELIVERY_DELAY_MS = 15_000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SAFE_DEVICE_ID = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$/;
const AWARE_DATE_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;

const PROTOCOL_VERSION = 1;
export const PI_DEVICE_SUBPROTOCOL = "fingerspeak.device.v1";

export const DEFAULT_PI_CAPTION = "Asha is ready. Your next message will appear here.";

export function createDemoTelemetry(caption = DEFAULT_PI_CAPTION): PiTelemetry {
  return {
    caption,
    tracking: null,
    camera: "unknown",
    phoneConnected: null,
    piPowerPercent: null,
    wheelchairBatteryPercent: null,
    lastSeen: null,
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function percent(value: unknown): number | null | undefined {
  if (value === null) return null;
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > 100) return undefined;
  return Math.round(value);
}

function booleanOrNull(value: unknown): boolean | null | undefined {
  return value === null || typeof value === "boolean" ? value : undefined;
}

function cameraState(value: unknown): PiCameraState | undefined {
  return value === "ready" || value === "off" || value === "error" || value === "unknown" ? value : undefined;
}

function hasExactlyKeys(value: Record<string, unknown>, keys: ReadonlyArray<string>): boolean {
  const actual = Object.keys(value);
  return actual.length === keys.length && actual.every((key) => keys.includes(key));
}

function isAwareDateTime(value: unknown): value is string {
  return typeof value === "string" && AWARE_DATE_TIME.test(value) && Number.isFinite(Date.parse(value));
}

/** Strictly parses one authenticated, media-free semantic event from the Pi. */
export function parsePiPatientIntentMessage(raw: string): PiPatientIntent | null {
  try {
    const value: unknown = JSON.parse(raw);
    if (!isRecord(value) || !hasExactlyKeys(value, ["version", "message_id", "device_id", "type", "sent_at", "sequence", "payload"])) return null;
    if (value.version !== PROTOCOL_VERSION || value.type !== "patient.intent") return null;
    if (typeof value.message_id !== "string" || !UUID.test(value.message_id)) return null;
    if (typeof value.device_id !== "string" || !SAFE_DEVICE_ID.test(value.device_id)) return null;
    if (!isAwareDateTime(value.sent_at) || !Number.isSafeInteger(value.sequence) || Number(value.sequence) < 0) return null;
    if (!isRecord(value.payload) || !hasExactlyKeys(value.payload, ["intent", "confidence", "detected_at"])) return null;
    if (!PI_PATIENT_INTENTS.includes(value.payload.intent as PiPatientIntentName)) return null;
    if (typeof value.payload.confidence !== "number" || !Number.isFinite(value.payload.confidence) || value.payload.confidence < 0 || value.payload.confidence > 1) return null;
    if (!isAwareDateTime(value.payload.detected_at)) return null;
    return {
      messageId: value.message_id,
      deviceId: value.device_id,
      sequence: Number(value.sequence),
      sentAt: value.sent_at,
      intent: value.payload.intent as PiPatientIntentName,
      confidence: value.payload.confidence,
      detectedAt: value.payload.detected_at,
    };
  } catch {
    return null;
  }
}

/** Defensive replay/flood gate in addition to the edge's hold, release, and cooldown policy. */
export class PiPatientIntentGate {
  private readonly seenMessageIds = new Map<string, number>();
  private lastAcceptedAt = Number.NEGATIVE_INFINITY;
  private lastIntentSequence = -1;

  accept(event: PiPatientIntent, now = Date.now()): boolean {
    const detectedAt = Date.parse(event.detectedAt);
    const sentAt = Date.parse(event.sentAt);
    if (detectedAt > now + PI_INTENT_MAX_FUTURE_SKEW_MS || sentAt > now + PI_INTENT_MAX_FUTURE_SKEW_MS) return false;
    if (now - detectedAt > PI_INTENT_MAX_AGE_MS || now - sentAt > PI_INTENT_MAX_AGE_MS) return false;
    if (detectedAt > sentAt + 1_000 || sentAt - detectedAt > PI_INTENT_MAX_DELIVERY_DELAY_MS) return false;

    for (const [messageId, seenAt] of this.seenMessageIds) {
      if (now - seenAt > PI_INTENT_MAX_AGE_MS * 2) this.seenMessageIds.delete(messageId);
    }
    if (this.seenMessageIds.has(event.messageId)) return false;
    this.seenMessageIds.set(event.messageId, now);
    while (this.seenMessageIds.size > 256) this.seenMessageIds.delete(this.seenMessageIds.keys().next().value!);

    if (event.sequence <= this.lastIntentSequence) return false;
    this.lastIntentSequence = event.sequence;
    if (now - this.lastAcceptedAt < PI_INTENT_COOLDOWN_MS) return false;
    this.lastAcceptedAt = now;
    return true;
  }

  reset(): void {
    this.seenMessageIds.clear();
    this.lastAcceptedAt = Number.NEGATIVE_INFINITY;
    this.lastIntentSequence = -1;
  }
}

/**
 * Parses the bounded telemetry envelope expected from the future Raspberry Pi
 * edge service. Unknown fields are ignored so the browser can remain forward
 * compatible without treating malformed values as real telemetry.
 */
export function parsePiTelemetryMessage(raw: string): Partial<PiTelemetry> | null {
  let decoded: unknown;
  try {
    decoded = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!isRecord(decoded) || !["device.status", "telemetry"].includes(String(decoded.type))) return null;
  const payload = isRecord(decoded.payload)
    ? decoded.payload
    : isRecord(decoded.telemetry)
      ? decoded.telemetry
      : decoded;
  const result: Partial<PiTelemetry> = {};

  if (typeof payload.caption === "string" && payload.caption.trim()) result.caption = payload.caption.trim().slice(0, 500);
  const trackingValue = payload.tracking_status === "tracking"
    ? true
    : ["idle", "lost", "paused", "error"].includes(String(payload.tracking_status))
      ? false
      : payload.tracking;
  const nextTracking = booleanOrNull(trackingValue);
  if (nextTracking !== undefined) result.tracking = nextTracking;
  const edgeCamera = payload.camera_status === "degraded" ? "error" : payload.camera_status === "starting" ? "unknown" : payload.camera_status;
  const nextCamera = cameraState(edgeCamera ?? payload.camera);
  if (nextCamera !== undefined) result.camera = nextCamera;
  const nextPhone = booleanOrNull(payload.phone_connected ?? payload.phoneConnected);
  if (nextPhone !== undefined) result.phoneConnected = nextPhone;
  const piPowerValue = Object.prototype.hasOwnProperty.call(payload, "pi_battery_percent")
    ? payload.pi_battery_percent
    : payload.piPowerPercent;
  const nextPiPower = percent(piPowerValue);
  if (nextPiPower !== undefined) result.piPowerPercent = nextPiPower;
  const wheelchairBatteryValue = Object.prototype.hasOwnProperty.call(payload, "wheelchair_battery_percent")
    ? payload.wheelchair_battery_percent
    : payload.wheelchairBatteryPercent;
  const nextWheelchairBattery = percent(wheelchairBatteryValue);
  if (nextWheelchairBattery !== undefined) result.wheelchairBatteryPercent = nextWheelchairBattery;
  const seenAt = typeof decoded.sent_at === "string" ? decoded.sent_at : payload.lastSeen;
  if (typeof seenAt === "string" && Number.isFinite(Date.parse(seenAt))) result.lastSeen = seenAt;

  return Object.keys(result).length ? result : null;
}

function envelope(deviceId: string, sequence: number, type: string, payload: Record<string, unknown>, sentAt = new Date().toISOString()) {
  return {
    version: PROTOCOL_VERSION,
    message_id: typeof crypto.randomUUID === "function" ? crypto.randomUUID() : `00000000-0000-4000-8000-${Date.now().toString().padStart(12, "0").slice(-12)}`,
    device_id: deviceId,
    type,
    sent_at: sentAt,
    sequence,
    payload,
  };
}

export function createCaptionCommand(caption: string, deviceId: string, sequence: number, language = "en-US") {
  return envelope(deviceId, sequence, "caption.set", {
    text: caption.trim().slice(0, 280),
    language,
  });
}

export function createEmergencyDisplayCommand(text: string, deviceId: string, sequence: number, language = "en-US") {
  return envelope(deviceId, sequence, "emergency.display", {
    text: text.trim().slice(0, 500),
    language,
    expires_at: new Date(Date.now() + 5 * 60 * 1_000).toISOString(),
  });
}

export function createHeartbeatCommand(deviceId: string, sequence: number) {
  return envelope(deviceId, sequence, "heartbeat", {});
}

export function createPairingAuthentication(
  credential: string,
  deviceId: string,
  phoneId: string,
  credentialKind: PiCredentialKind,
  sequence: number,
) {
  return envelope(deviceId, sequence, "pairing.authenticate", {
    credential_kind: credentialKind,
    credential,
    phone_id: phoneId,
  });
}

export function parsePairingAuthenticatedMessage(raw: string): PairingAuthenticated | null {
  try {
    const value: unknown = JSON.parse(raw);
    if (!isRecord(value) || value.type !== "pairing.authenticated" || !isRecord(value.payload)) return null;
    const heartbeat = value.payload.heartbeat_interval_seconds;
    const credential = value.payload.device_credential;
    if (typeof heartbeat !== "number" || !Number.isFinite(heartbeat) || heartbeat <= 0) return null;
    if (credential !== null && credential !== undefined && typeof credential !== "string") return null;
    return {
      deviceCredential: typeof credential === "string" ? credential : null,
      heartbeatIntervalSeconds: heartbeat,
    };
  } catch {
    return null;
  }
}

export function parsePiCommandResult(raw: string): PiCommandResult | null {
  try {
    const value: unknown = JSON.parse(raw);
    if (!isRecord(value) || !isRecord(value.payload)) return null;
    if (value.type === "command.ack") {
      const commandId = value.payload.command_id;
      const commandType = value.payload.command_type;
      const accepted = value.payload.accepted;
      const detail = value.payload.detail;
      const validTypes = ["heartbeat", "status.get", "caption.set", "emergency.display"];
      if (typeof commandId !== "string" || typeof accepted !== "boolean" || typeof detail !== "string" || !validTypes.includes(String(commandType))) return null;
      return { commandId, commandType: commandType as PiCommandResult["commandType"], accepted, detail: detail.slice(0, 240) };
    }
    if (value.type === "protocol.error") {
      const commandId = value.payload.ref_message_id;
      const detail = value.payload.detail;
      if (typeof commandId !== "string" || typeof detail !== "string") return null;
      return { commandId, commandType: "unknown", accepted: false, detail: detail.slice(0, 240) };
    }
    return null;
  } catch {
    return null;
  }
}

export function normalizePiWebSocketUrl(value: string): string {
  const trimmed = value.trim();
  if (!trimmed) return "";
  const url = new URL(trimmed);
  if (url.protocol !== "ws:" && url.protocol !== "wss:") throw new Error("Use a ws:// or wss:// Raspberry Pi address.");
  if (url.username || url.password) throw new Error("Do not put credentials in the Raspberry Pi address.");
  if (["token", "access_token", "auth"].some((name) => url.searchParams.has(name))) throw new Error("Store the pairing token separately, not in the Pi URL.");
  url.hash = "";
  return url.toString();
}
