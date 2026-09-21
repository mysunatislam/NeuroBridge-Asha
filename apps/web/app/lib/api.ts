import type { FingerSpeakProfile } from "./fingerspeak";
import { deviceStorage, type OutboxEvent, type RemoteLink } from "./storage";
import { askMaira, type SomaticEvent } from "./maira-api";

const API_BASE = (process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000/v1").replace(/\/$/, "");
const JSON_HEADERS = { "content-type": "application/json" };

export type CaregiverAlert = {
  id: string;
  profile_id: string;
  session_id: string;
  source_event_id: string;
  severity: "routine" | "urgent" | "emergency";
  message: string;
  status: "pending" | "acknowledged" | "resolved";
  created_at: string;
  acknowledged_at: string | null;
  acknowledged_by: string | null;
  resolved_at: string | null;
};

export type AshaCitation = {
  title: string;
  url?: string;
  snippet?: string;
};

export type AshaChatRequest = {
  message: string;
  previous_response_id?: string;
  locale?: string;
  patient_context?: Record<string, unknown>;
  somatic_events?: SomaticEvent[];
};

export type AshaChatResponse = {
  reply: string;
  mode: string;
  previous_response_id?: string;
  citations: AshaCitation[];
  urgent: boolean;
};

export type RemoteDeviceState = {
  sequence: number;
  observed_at: string;
  last_seen_at: string;
  pi_battery_percent: number | null;
  wheelchair_battery_percent: number | null;
  wheelchair_status: "unknown" | "idle" | "moving" | "stopped" | "needs_attention";
  camera_status: "unknown" | "off" | "ready" | "active" | "error";
  display_status: "unknown" | "off" | "ready" | "active" | "error";
  transport: "unknown" | "wifi" | "usb" | "ethernet";
};

export type RemoteDevice = {
  id: string;
  profile_id: string;
  name: string;
  enabled: boolean;
  online: boolean;
  last_state: RemoteDeviceState | null;
};

type ProfileResponse = { id: string };
type SessionResponse = { id: string };

class ApiError extends Error {
  constructor(readonly status: number) {
    super(`FingerSpeak API returned ${status}.`);
  }
}

let creatingLink: Promise<RemoteLink | null> | null = null;
let activeLink: RemoteLink | null = null;
const consentPatchChains = new Map<string, Promise<boolean>>();
let outboxFlushChain: Promise<void> = Promise.resolve();
let latestOutboxProfile: FingerSpeakProfile | null = null;

async function requestJson<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${API_BASE}${path}`, {
    credentials: "include",
    ...init,
    headers: { ...JSON_HEADERS, ...(init?.headers ?? {}) },
  });
  if (!response.ok) throw new ApiError(response.status);
  return response.json() as Promise<T>;
}

export async function sendAshaChat(input: AshaChatRequest, signal?: AbortSignal): Promise<AshaChatResponse> {
  try {
    return await askMaira({
      message: input.message,
      locale: input.locale,
      patientContext: input.patient_context,
      recentSomaticEvents: input.somatic_events,
      signal,
    });
  } catch (error) {
    if (signal?.aborted) throw error;
    try {
      const response = await requestJson<AshaChatResponse>("/asha/chat", {
        method: "POST",
        body: JSON.stringify(input),
        signal,
      });
      if (response && typeof response.reply === "string" && response.reply.trim()) {
        return {
          reply: response.reply.trim(),
          mode: response.mode,
          previous_response_id: typeof response.previous_response_id === "string" ? response.previous_response_id : undefined,
          citations: Array.isArray(response.citations)
            ? response.citations.filter((c): c is AshaCitation => Boolean(c) && typeof c.title === "string")
            : [],
          urgent: response.urgent === true,
        };
      }
    } catch {
      // Ignore secondary error and rethrow main error
    }
    throw error;
  }
}

export async function loadRemoteDevices(profileId: string): Promise<RemoteDevice[]> {
  return requestJson(`/devices?profile_id=${encodeURIComponent(profileId)}&limit=20`);
}

export async function sendRemoteDeviceCaption(deviceId: string, text: string): Promise<void> {
  await requestJson(`/devices/${encodeURIComponent(deviceId)}/captions`, {
    method: "POST",
    body: JSON.stringify({
      client_message_id: crypto.randomUUID(),
      text: text.trim().slice(0, 500),
      locale: navigator.language || "en-US",
    }),
  });
}

function isUsableLink(value: RemoteLink | null, profile: FingerSpeakProfile): value is RemoteLink {
  return value !== null &&
    value.id === "remote-link" &&
    value.apiBase === API_BASE &&
    value.localProfileId === profile.id &&
    typeof value.profileId === "string" &&
    typeof value.sessionId === "string" &&
    typeof value.clientSessionId === "string" &&
    typeof value.telemetrySalt === "string" &&
    value.telemetrySalt.length >= 32;
}

async function createRemoteProfile(profile: FingerSpeakProfile): Promise<string> {
  const response = await requestJson<ProfileResponse>("/profiles", {
    method: "POST",
    body: JSON.stringify({
      display_name: "FingerSpeak profile",
      locale: "en-US",
      consent_version: "prototype-v1",
      consent_granted_at: new Date().toISOString(),
      analytics_consent: profile.consentToEventSync,
      caregiver_alerts_consent: profile.consentToCaregiverAlerts,
      model_sync_consent: false,
      // Analytics never needs labels or spoken phrases. Caregiver request text
      // is sent only in the separately consented alert endpoint.
      vocabulary: [],
    }),
  });
  return response.id;
}

async function startRemoteSession(profile: FingerSpeakProfile, profileId: string, telemetrySalt = crypto.randomUUID()): Promise<RemoteLink> {
  const clientSessionId = crypto.randomUUID();
  const session = await requestJson<SessionResponse>("/sessions", {
    method: "POST",
    body: JSON.stringify({
      profile_id: profileId,
      client_session_id: clientSessionId,
      device_id: "browser-device",
      client_version: "web-1.0.0",
      inference_location: "on_device",
      started_at: new Date().toISOString(),
    }),
  });
  const link: RemoteLink = {
    id: "remote-link",
    profileId,
    sessionId: session.id,
    clientSessionId,
    localProfileId: profile.id,
    apiBase: API_BASE,
    createdAt: new Date().toISOString(),
    telemetrySalt,
  };
  activeLink = link;
  await deviceStorage.saveRemoteLink(link);
  return link;
}

async function discardCurrentLink(): Promise<void> {
  activeLink = null;
  await deviceStorage.clearRemoteLink();
}

async function recoverRemoteSession(profile: FingerSpeakProfile, link: RemoteLink): Promise<void> {
  try {
    await startRemoteSession(profile, link.profileId, link.telemetrySalt);
  } catch (error) {
    if (!(error instanceof ApiError) || ![404, 410].includes(error.status)) throw error;
    try {
      await requestJson(`/profiles/${link.profileId}`);
    } catch (profileError) {
      if (profileError instanceof ApiError && [404, 410].includes(profileError.status)) {
        await discardCurrentLink();
        return;
      }
      throw profileError;
    }
    throw error;
  }
}

export async function ensureRemoteLink(profile: FingerSpeakProfile): Promise<RemoteLink | null> {
  if (isUsableLink(activeLink, profile)) return activeLink;
  if (creatingLink) return creatingLink;
  creatingLink = (async () => {
    try {
      const saved = await deviceStorage.loadRemoteLink();
      if (isUsableLink(saved, profile)) {
        try {
          // A browser lifetime is a usage session. Do not silently reuse an
          // abandoned session from a previous tab or app launch.
          return await startRemoteSession(profile, saved.profileId, saved.telemetrySalt);
        } catch (error) {
          if (!(error instanceof ApiError) || ![404, 410].includes(error.status)) throw error;
          await discardCurrentLink();
        }
      } else if (saved) {
        await discardCurrentLink();
      }
      const profileId = await createRemoteProfile(profile);
      return await startRemoteSession(profile, profileId);
    } catch {
      return null;
    } finally {
      creatingLink = null;
    }
  })();
  return creatingLink;
}

export async function syncRemoteProfile(profile: FingerSpeakProfile): Promise<RemoteLink | null> {
  const saved = activeLink ?? await deviceStorage.loadRemoteLink();
  let link = isUsableLink(saved, profile) ? saved : null;
  if (!link && !profile.consentToEventSync && !profile.consentToCaregiverAlerts) return null;
  if (!link) link = await ensureRemoteLink(profile);
  if (!link) return null;

  const pending = {
    apiBase: API_BASE,
    profileId: link.profileId,
    analyticsConsent: profile.consentToEventSync,
    caregiverAlertsConsent: profile.consentToCaregiverAlerts,
  };
  const applied = await processPendingConsentUpdate(`pending-consent:${API_BASE}:${link.profileId}`, pending);
  return applied ? link : null;
}

export async function flushPendingConsentUpdates(): Promise<void> {
  for (const update of await deviceStorage.listPendingConsentUpdates()) {
    if (update.apiBase !== API_BASE) continue;
    await processPendingConsentUpdate(update.id);
  }
}

function processPendingConsentUpdate(
  id: string,
  nextUpdate?: { apiBase: string; profileId: string; analyticsConsent: boolean; caregiverAlertsConsent: boolean },
): Promise<boolean> {
  const previous = consentPatchChains.get(id) ?? Promise.resolve(true);
  const run = async () => {
    if (nextUpdate) await deviceStorage.queueConsentUpdate(nextUpdate);
    for (let pass = 0; pass < 5; pass += 1) {
      const update = (await deviceStorage.listPendingConsentUpdates()).find((item) => item.id === id);
      if (!update) return true;
      try {
        await requestJson(`/profiles/${update.profileId}`, {
          method: "PATCH",
          body: JSON.stringify({
            analytics_consent: update.analyticsConsent,
            caregiver_alerts_consent: update.caregiverAlertsConsent,
            model_sync_consent: false,
          }),
        });
        const latest = (await deviceStorage.listPendingConsentUpdates()).find((item) => item.id === id);
        if (!latest) return true;
        if (latest.analyticsConsent === update.analyticsConsent && latest.caregiverAlertsConsent === update.caregiverAlertsConsent) {
          await deviceStorage.deletePendingConsentUpdate(id);
          return true;
        }
        // A newer toggle arrived during the request; apply it in this same
        // serialized chain so an older response can never win.
      } catch (error) {
        if (error instanceof ApiError && [404, 410].includes(error.status)) {
          await deviceStorage.deletePendingConsentUpdate(id);
          if (activeLink?.profileId === update.profileId) await discardCurrentLink();
          return true;
        }
        return false;
      }
    }
    return false;
  };
  const current: Promise<boolean> = previous.catch(() => false).then(async () => {
    if (typeof navigator !== "undefined" && navigator.locks) {
      return await navigator.locks.request<Promise<boolean>>(`fingerspeak-consent:${id}`, run);
    }
    return await run();
  });
  consentPatchChains.set(id, current);
  const cleanup = () => {
    if (consentPatchChains.get(id) === current) consentPatchChains.delete(id);
  };
  void current.then(cleanup, cleanup);
  return current;
}

export type EventDeliveryResult = "sent" | "retry" | "discard";

async function sendEventOnce(profile: FingerSpeakProfile, event: OutboxEvent, signal?: AbortSignal): Promise<EventDeliveryResult> {
  const link = await ensureRemoteLink(profile);
  if (!link) return "retry";
  try {
    if (event.type === "caregiver_alert") {
      await requestJson("/events/caregiver-alerts", {
        method: "POST",
        body: JSON.stringify({
          profile_id: link.profileId,
          session_id: link.sessionId,
          client_event_id: event.id,
          severity: event.risk === "emergency" ? "emergency" : event.risk === "clinical" ? "urgent" : "routine",
          message: event.phrase ?? "Assistance requested",
          requested_at: event.occurredAt,
        }),
        signal,
      });
    } else {
      await requestJson("/events", {
        method: "POST",
        body: JSON.stringify({
          session_id: link.sessionId,
          client_event_id: event.id,
          event_type: event.type,
          occurred_at: event.occurredAt,
          gesture_key: event.gestureId ? await opaqueGestureKey(link.telemetrySalt, event.gestureId) : undefined,
        }),
        signal,
      });
    }
    return "sent";
  } catch (error) {
    if (error instanceof ApiError) {
      if ([404, 410].includes(error.status)) {
        try {
          await recoverRemoteSession(profile, link);
        } catch {
          // Keep the event queued; a later authenticated probe can retry.
        }
        return "retry";
      }
      if ([400, 405, 409, 413, 415, 422].includes(error.status)) return "discard";
    }
    return "retry";
  }
}

export async function sendEvent(profile: FingerSpeakProfile, event: OutboxEvent, signal?: AbortSignal): Promise<EventDeliveryResult> {
  const first = await sendEventOnce(profile, event, signal);
  if (first !== "retry" || signal?.aborted) return first;
  return sendEventOnce(profile, event, signal);
}

async function flushOutboxNow(): Promise<void> {
  const profile = latestOutboxProfile;
  if (!profile) return;
  const events = (await deviceStorage.listOutbox())
    .sort((left, right) => Number(right.type === "caregiver_alert") - Number(left.type === "caregiver_alert") || left.occurredAt.localeCompare(right.occurredAt))
    .slice(0, 100);
  const now = Date.now();
  for (const event of events) {
    if (event.profileId !== profile.id) {
      await deviceStorage.deleteEvent(event.id);
      continue;
    }
    const allowed = event.type === "caregiver_alert" ? profile.consentToCaregiverAlerts : profile.consentToEventSync;
    const age = now - Date.parse(event.occurredAt);
    const expired = !Number.isFinite(age) || age < 0 || (event.type === "caregiver_alert" ? age > 120_000 : age > 7 * 24 * 60 * 60 * 1_000);
    if (!allowed || expired) {
      await deviceStorage.deleteEvent(event.id);
      continue;
    }
    const result = await sendEvent(profile, event);
    if (result !== "retry") await deviceStorage.deleteEvent(event.id);
  }
}

export function flushOutbox(profile: FingerSpeakProfile): Promise<void> {
  latestOutboxProfile = profile;
  outboxFlushChain = outboxFlushChain.catch(() => undefined).then(flushOutboxNow);
  return outboxFlushChain;
}

export async function detachRemoteProfile(profile: FingerSpeakProfile): Promise<void> {
  const revoked = { ...profile, consentToEventSync: false, consentToCaregiverAlerts: false };
  await syncRemoteProfile(revoked);
  await deviceStorage.clearOutbox();
  await discardCurrentLink();
}

export function endRemoteSession(): void {
  if (!activeLink) return;
  void fetch(`${API_BASE}/sessions/${activeLink.sessionId}/end`, {
    method: "POST",
    credentials: "include",
    keepalive: true,
    headers: JSON_HEADERS,
    body: JSON.stringify({ ended_at: new Date().toISOString() }),
  });
  activeLink = null;
}

export async function checkApi(signal?: AbortSignal): Promise<boolean> {
  try {
    return (await fetch(`${API_BASE.replace(/\/v1$/, "")}/health/ready`, { credentials: "include", signal })).ok;
  } catch {
    return false;
  }
}

export async function loadCaregiverAlerts(profileId: string): Promise<CaregiverAlert[]> {
  return requestJson(`/events/caregiver-alerts?profile_id=${encodeURIComponent(profileId)}&limit=100`);
}

export async function updateCaregiverAlert(alertId: string, action: "acknowledge" | "resolve"): Promise<CaregiverAlert> {
  return requestJson(`/events/caregiver-alerts/${encodeURIComponent(alertId)}/${action}`, { method: "POST", body: "{}" });
}

export async function grantCaregiver(profileId: string, caregiverSubject: string): Promise<void> {
  await requestJson(`/profiles/${encodeURIComponent(profileId)}/caregivers`, {
    method: "PUT",
    body: JSON.stringify({ caregiver_subject: caregiverSubject }),
  });
}

export function caregiverSocketUrl(profileId: string): string {
  return `${API_BASE.replace(/^http/, "ws")}/events/caregiver-alerts/ws?profile_id=${encodeURIComponent(profileId)}`;
}

async function opaqueGestureKey(salt: string, gestureId: string): Promise<string> {
  const bytes = new TextEncoder().encode(`${salt}\u0000${gestureId}`);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  const hex = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `g-${hex}`;
}
