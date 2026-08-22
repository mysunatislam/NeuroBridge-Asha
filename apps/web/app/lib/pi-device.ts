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
