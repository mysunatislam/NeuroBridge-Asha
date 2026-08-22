import { computed, ref } from "vue";
import { defineStore } from "pinia";
import {
  checkApi,
  detachRemoteProfile,
  endRemoteSession,
  flushOutbox,
  flushPendingConsentUpdates,
  sendEvent,
  syncRemoteProfile,
} from "../lib/api";
import {
  createDefaultProfile,
  parseProfile,
  profileModelFingerprint,
  type FingerSpeakProfile,
  type Gesture,
  type PrototypeModel,
} from "../lib/fingerspeak";
import { deviceStorage, type OutboxEvent } from "../lib/storage";

export type SpokenEntry = {
  id: string;
  phrase: string;
  gesture: string;
  risk: Gesture["risk"];
  at: string;
  source: "gesture" | "touch";
};

function eventId(): string {
  if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0"));
  return `${hex.slice(0, 4).join("")}-${hex.slice(4, 6).join("")}-${hex.slice(6, 8).join("")}-${hex.slice(8, 10).join("")}-${hex.slice(10).join("")}`;
}

export const useFingerSpeakStore = defineStore("fingerspeak", () => {
  const profile = ref<FingerSpeakProfile>(createDefaultProfile());
  const model = ref<PrototypeModel | null>(null);
  const serverOnline = ref(false);
  const remoteProfileId = ref<string | null>(null);
  const caregiverProfileId = ref<string | null>(null);
  const spoken = ref<SpokenEntry[]>([]);
  const falseActivations = ref(0);
  const missedGestures = ref(0);
  const statusMessage = ref("Local workspace ready.");
  const initialized = ref(false);
  let connectivityTimer: number | null = null;

  const calibrationReady = computed(() => profile.value.gestures.every((gesture) => gesture.samples.length >= 2));
  const capturedCount = computed(() => profile.value.gestures.reduce((sum, gesture) => sum + gesture.samples.length, 0));
  const requiredCount = computed(() => profile.value.gestures.length * 2);

  async function bootstrap(): Promise<void> {
    if (initialized.value) return;
    try {
      const [savedProfile, savedModel, savedLink, consentGuard] = await Promise.all([
        deviceStorage.loadProfile("local-profile"),
        deviceStorage.loadModel("local-profile"),
        deviceStorage.loadRemoteLink(),
        deviceStorage.loadConsentGuard("local-profile"),
      ]);

      let restored = createDefaultProfile();
      if (savedProfile) {
        restored = parseProfile(savedProfile, { preserveLocalConsent: true });
        if (consentGuard) {
          restored = {
            ...restored,
            consentToEventSync: restored.consentToEventSync && !consentGuard.eventSyncDenied,
            consentToCaregiverAlerts: restored.consentToCaregiverAlerts && !consentGuard.caregiverAlertsDenied,
          };
        }
      }
      profile.value = restored;

      if (savedModel) {
        const expectedFingerprint = await profileModelFingerprint(restored);
        const expectedGestureIds = restored.gestures.map((gesture) => gesture.id);
        const savedGestureIds = savedModel.prototypes?.map((prototype) => prototype.gestureId) ?? [];
        const valid =
          savedModel.featureVersion === "3d-angle-motion-v1" &&
          savedModel.sequenceLength === 20 &&
          savedModel.featureLength === 98 &&
          savedModel.profileFingerprint === expectedFingerprint &&
          expectedGestureIds.length === savedGestureIds.length &&
          expectedGestureIds.every((id, index) => id === savedGestureIds[index]) &&
          savedModel.prototypes.every((prototype) =>
            prototype.centroid.length === 196 &&
            prototype.centroid.every(Number.isFinite) &&
            Number.isFinite(prototype.spread) &&
            prototype.spread >= 0.05,
          );
        if (valid) model.value = savedModel;
        else {
          await deviceStorage.deleteModel("local-profile");
          statusMessage.value = "A stale edge model was removed. Recalibrate or import its matching bundle.";
        }
      }

      if (savedLink?.localProfileId === restored.id) {
        remoteProfileId.value = savedLink.profileId;
        caregiverProfileId.value = savedLink.profileId;
      }
    } catch {
      statusMessage.value = "Device storage is unavailable. The app remains local-only until storage is restored.";
    } finally {
      initialized.value = true;
    }
  }

  async function saveProfile(next: FingerSpeakProfile): Promise<void> {
    await deviceStorage.saveProfile(next);
    profile.value = next;
  }

  async function activateModel(next: PrototypeModel): Promise<void> {
    await deviceStorage.saveProfileAndModel(profile.value, next);
    model.value = next;
  }

  async function clearModel(): Promise<void> {
    model.value = null;
    await deviceStorage.deleteModel(profile.value.id);
  }

  function logSpoken(gesture: Gesture, source: SpokenEntry["source"]): SpokenEntry {
    const entry: SpokenEntry = {
      id: eventId(),
      phrase: gesture.phrase,
      gesture: gesture.name,
      risk: gesture.risk,
      at: new Date().toISOString(),
      source,
    };
    spoken.value = [entry, ...spoken.value].slice(0, 30);
    return entry;
  }

  async function queueEvent(gesture: Gesture, type: OutboxEvent["type"]): Promise<void> {
    const active = profile.value;
    const maySync = type === "caregiver_alert" ? active.consentToCaregiverAlerts : active.consentToEventSync;
    if (!maySync) return;
    const event: OutboxEvent = {
      id: eventId(),
      type,
      profileId: active.id,
      gestureId: gesture.id,
      phrase: type === "caregiver_alert" ? gesture.phrase : undefined,
      risk: type === "caregiver_alert" ? gesture.risk : undefined,
      occurredAt: new Date().toISOString(),
    };
    await deviceStorage.queueEvent(event);
    try {
      const delivery = await sendEvent(active, event);
      if (delivery !== "retry") await deviceStorage.deleteEvent(event.id);
      if (delivery === "sent") serverOnline.value = true;
    } catch {
      // The durable local outbox is the source of truth until connectivity returns.
    }
  }

  async function updateConsent(field: "consentToEventSync" | "consentToCaregiverAlerts", value: boolean): Promise<void> {
    const next = { ...profile.value, [field]: value, updatedAt: new Date().toISOString() };
    if (!value) profile.value = next;
    try {
      await deviceStorage.saveProfileAndConsentGuard(next);
      profile.value = next;
      await probeConnectivity();
    } catch {
      statusMessage.value = value
        ? "Cloud sharing was not enabled because the consent choice could not be saved locally."
        : "Cloud sharing is off in this session, but the withdrawal could not be persisted yet.";
    }
  }

  async function replaceProfile(imported: FingerSpeakProfile): Promise<void> {
    await detachRemoteProfile(profile.value);
    const next = { ...imported, id: "local-profile" };
    await deviceStorage.deleteModel("local-profile");
    await deviceStorage.saveProfileAndConsentGuard(next);
    profile.value = next;
    model.value = null;
    remoteProfileId.value = null;
    caregiverProfileId.value = null;
  }

  async function probeConnectivity(): Promise<void> {
    const online = await checkApi();
    serverOnline.value = online;
    if (!online) return;
    await flushPendingConsentUpdates();
    const link = await syncRemoteProfile(profile.value);
    if (link) {
      remoteProfileId.value = link.profileId;
      caregiverProfileId.value ??= link.profileId;
    }
    await flushOutbox(profile.value);
  }

  function startConnectivityLoop(): void {
    if (connectivityTimer !== null) return;
    void probeConnectivity();
    connectivityTimer = window.setInterval(() => void probeConnectivity(), 15_000);
    window.addEventListener("online", probeConnectivity);
  }

  function stopConnectivityLoop(): void {
    if (connectivityTimer !== null) window.clearInterval(connectivityTimer);
    connectivityTimer = null;
    window.removeEventListener("online", probeConnectivity);
  }

  function markFalseActivation(): void {
    falseActivations.value += 1;
    const rest = profile.value.gestures.find((gesture) => gesture.id === "rest");
    if (rest) void queueEvent(rest, "false_activation");
  }

  function markMissedGesture(): void {
    missedGestures.value += 1;
    const rest = profile.value.gestures.find((gesture) => gesture.id === "rest");
    if (rest) void queueEvent(rest, "missed_gesture");
  }

  return {
    profile,
    model,
    serverOnline,
    remoteProfileId,
    caregiverProfileId,
    spoken,
    falseActivations,
    missedGestures,
    statusMessage,
    calibrationReady,
    capturedCount,
    requiredCount,
    bootstrap,
    saveProfile,
    activateModel,
    clearModel,
    logSpoken,
    queueEvent,
    updateConsent,
    replaceProfile,
    probeConnectivity,
    startConnectivityLoop,
    stopConnectivityLoop,
    markFalseActivation,
    markMissedGesture,
    endRemoteSession,
  };
});
