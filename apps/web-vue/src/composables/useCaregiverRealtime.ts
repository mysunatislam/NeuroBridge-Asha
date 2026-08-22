import { onBeforeUnmount, ref, watch } from "vue";
import {
  caregiverSocketUrl,
  grantCaregiver,
  loadCaregiverAlerts,
  updateCaregiverAlert,
  type CaregiverAlert,
} from "../lib/api";
import { useFingerSpeakStore } from "../stores/fingerspeak";

export function useCaregiverRealtime() {
  const store = useFingerSpeakStore();
  const alerts = ref<CaregiverAlert[]>([]);
  const socketStatus = ref<"offline" | "connecting" | "live">("offline");
  const profileInput = ref(store.caregiverProfileId ?? "");
  const caregiverSubject = ref("");
  const message = ref("Enter an authorized profile ID to use this dashboard on another device.");
  let socket: WebSocket | null = null;
  let reconnectTimer: number | null = null;
  let reconnectAttempt = 0;
  let disposed = false;

  function mergeAlerts(incoming: CaregiverAlert[]): void {
    const merged = [...incoming, ...alerts.value]
      .filter((item, index, all) => all.findIndex((candidate) => candidate.id === item.id) === index)
      .sort((left, right) => right.created_at.localeCompare(left.created_at))
      .slice(0, 100);
    alerts.value = merged;
  }

  function closeSocket(): void {
    if (reconnectTimer !== null) window.clearTimeout(reconnectTimer);
    reconnectTimer = null;
    if (socket) {
      socket.onopen = null;
      socket.onmessage = null;
      socket.onerror = null;
      socket.onclose = null;
      socket.close(1000, "leaving caregiver view");
    }
    socket = null;
    socketStatus.value = "offline";
  }

  async function open(profileId: string): Promise<void> {
    closeSocket();
    if (!store.serverOnline || disposed) return;
    try {
      mergeAlerts(await loadCaregiverAlerts(profileId));
    } catch {
      // The WebSocket may still establish; durable replay will fill any gap.
    }

    const connect = () => {
      if (disposed || !store.serverOnline) return;
      socketStatus.value = "connecting";
      socket = new WebSocket(caregiverSocketUrl(profileId));
      socket.onopen = () => {
        reconnectAttempt = 0;
        socketStatus.value = "live";
        message.value = "Authorized caregiver connection is live.";
      };
      socket.onmessage = (event) => {
        try {
          const payload = JSON.parse(String(event.data)) as { alert?: CaregiverAlert; alerts?: CaregiverAlert[] };
          const incoming = payload.alerts ?? (payload.alert ? [payload.alert] : []);
          if (incoming.length) mergeAlerts(incoming);
        } catch {
          // Ignore malformed network messages; the durable API remains authoritative.
        }
      };
      socket.onerror = () => socket?.close();
      socket.onclose = (event) => {
        if (disposed) return;
        socketStatus.value = "offline";
        if ([4401, 4403, 4404].includes(event.code)) {
          message.value = event.code === 4401
            ? "Caregiver sign-in is required."
            : event.code === 4403
              ? "Caregiver alerts are not consented for this profile."
              : "Profile not found or access was revoked.";
          return;
        }
        const delay = Math.min(30_000, 1_500 * (2 ** reconnectAttempt)) + Math.floor(Math.random() * 500);
        reconnectAttempt += 1;
        reconnectTimer = window.setTimeout(connect, delay);
      };
    };
    connect();
  }

  function connectProfile(): void {
    const candidate = profileInput.value.trim();
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(candidate)) {
      message.value = "Enter a valid shared profile UUID.";
      return;
    }
    alerts.value = [];
    store.caregiverProfileId = candidate;
    message.value = "Connecting with your authenticated caregiver account…";
  }

  async function actOnAlert(alert: CaregiverAlert, action: "acknowledge" | "resolve"): Promise<void> {
    try {
      const updated = await updateCaregiverAlert(alert.id, action);
      alerts.value = alerts.value.map((item) => item.id === updated.id ? updated : item);
    } catch {
      message.value = "The alert could not be updated. Check caregiver access and connection.";
    }
  }

  async function grantAccess(): Promise<void> {
    if (!store.remoteProfileId || !caregiverSubject.value.trim()) {
      message.value = "Create the remote profile first and enter the caregiver’s authenticated subject.";
      return;
    }
    try {
      await grantCaregiver(store.remoteProfileId, caregiverSubject.value.trim());
      caregiverSubject.value = "";
      message.value = "Caregiver access granted. Share the profile ID through a trusted channel.";
    } catch {
      message.value = "Caregiver access could not be granted. Only the profile owner may grant access.";
    }
  }

  watch(
    () => [store.serverOnline, store.caregiverProfileId] as const,
    ([online, profileId]) => {
      if (online && profileId) void open(profileId);
      else closeSocket();
    },
    { immediate: true },
  );

  onBeforeUnmount(() => {
    disposed = true;
    closeSocket();
  });

  return {
    alerts,
    socketStatus,
    profileInput,
    caregiverSubject,
    message,
    connectProfile,
    actOnAlert,
    grantAccess,
  };
}
