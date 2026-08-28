import { deviceStorage } from "./storage";

const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$/;
const CLOCK_TIME = /^(?:[01]\d|2[0-3]):[0-5]\d$/;

export type ScheduledRoutineKind = "hydration" | "check-in";
export type RoutineDefinition = { enabled: boolean; intervalMinutes: number; activeFrom: string; activeUntil: string };
export type CareRoutineSettings = {
  id: string;
  profileId: string;
  hydration: RoutineDefinition & { message: string };
  checkIns: RoutineDefinition & { messages: string[] };
  updatedAt: string;
};
export type CareRoutineProgress = {
  id: string;
  profileId: string;
  lastHydrationAt: string;
  lastCheckInAt: string;
  nextCheckInIndex: number;
  updatedAt: string;
};
export type DueCareRoutine = { kind: ScheduledRoutineKind; phraseId: string; message: string; dueAt: string };
export type CareRoutineStore = {
  loadCareRoutineSettings(profileId: string): Promise<CareRoutineSettings | null>;
  loadCareRoutineProgress(profileId: string): Promise<CareRoutineProgress | null>;
  saveCareRoutineProgress(progress: CareRoutineProgress): Promise<void>;
};

export function createDefaultCareRoutineSettings(profileId: string, now = new Date()): CareRoutineSettings {
  requireId(profileId);
  return {
    id: `care-routines:${profileId}`, profileId,
    hydration: { enabled: true, intervalMinutes: 120, activeFrom: "08:00", activeUntil: "20:00", message: "It may be time for some water. Would you like a drink?" },
    checkIns: {
      enabled: true, intervalMinutes: 60, activeFrom: "08:00", activeUntil: "21:00",
      messages: ["I’m right here with you.", "How are you feeling? You can use a gesture or tap a phrase.", "You’re doing well. I’m still here whenever you need me."],
    },
    updatedAt: now.toISOString(),
  };
}

export function validateCareRoutineSettings(value: CareRoutineSettings): CareRoutineSettings {
  const settings = structuredClone(value);
  requireId(settings.profileId);
  if (settings.id !== `care-routines:${settings.profileId}`) throw new Error("Care routine settings do not match the profile.");
  validateRoutine(settings.hydration, 15, 360, "Hydration");
  validateRoutine(settings.checkIns, 5, 240, "Check-in");
  settings.hydration.message = cleanMessage(settings.hydration.message, "Hydration message");
  if (!Array.isArray(settings.checkIns.messages) || settings.checkIns.messages.length < 1 || settings.checkIns.messages.length > 8) throw new Error("Configure between 1 and 8 reassuring check-in messages.");
  settings.checkIns.messages = settings.checkIns.messages.map((message) => cleanMessage(message, "Check-in message"));
  requireDate(settings.updatedAt, "Routine settings timestamp");
  return settings;
}

export async function saveLocalCareRoutineSettings(value: CareRoutineSettings): Promise<CareRoutineSettings> {
  const settings = validateCareRoutineSettings(value);
  await deviceStorage.saveCareRoutineSettings(settings);
  return settings;
}

export function createCareRoutineProgress(profileId: string, now = new Date()): CareRoutineProgress {
  requireId(profileId); const timestamp = now.toISOString();
  return { id: `care-routine-progress:${profileId}`, profileId, lastHydrationAt: timestamp, lastCheckInAt: timestamp, nextCheckInIndex: 0, updatedAt: timestamp };
}

export function validateCareRoutineProgress(value: CareRoutineProgress): CareRoutineProgress {
  const progress = structuredClone(value);
  requireId(progress.profileId);
  if (progress.id !== `care-routine-progress:${progress.profileId}`) throw new Error("Care routine progress does not match the profile.");
  requireDate(progress.lastHydrationAt, "Last hydration timestamp"); requireDate(progress.lastCheckInAt, "Last check-in timestamp"); requireDate(progress.updatedAt, "Routine progress timestamp");
  if (!Number.isSafeInteger(progress.nextCheckInIndex) || progress.nextCheckInIndex < 0) throw new Error("Check-in position is invalid.");
  return progress;
}

export function careRoutinesDue(settingsValue: CareRoutineSettings, progressValue: CareRoutineProgress, now = new Date()): DueCareRoutine[] {
  const settings = validateCareRoutineSettings(settingsValue); const progress = validateCareRoutineProgress(progressValue);
  if (settings.profileId !== progress.profileId) throw new Error("Routine settings and progress use different profiles.");
  const due: DueCareRoutine[] = [];
  if (isRoutineDue(settings.hydration, progress.lastHydrationAt, now)) due.push({ kind: "hydration", phraseId: "water-reminder", message: settings.hydration.message, dueAt: now.toISOString() });
  if (isRoutineDue(settings.checkIns, progress.lastCheckInAt, now)) {
    const index = progress.nextCheckInIndex % settings.checkIns.messages.length;
    due.push({ kind: "check-in", phraseId: `reassurance-${index + 1}`, message: settings.checkIns.messages[index], dueAt: now.toISOString() });
  }
  return due;
}

export function markCareRoutineDelivered(progressValue: CareRoutineProgress, routine: DueCareRoutine, now = new Date()): CareRoutineProgress {
  const progress = validateCareRoutineProgress(progressValue); const timestamp = now.toISOString();
  if (routine.kind === "hydration") progress.lastHydrationAt = timestamp;
  if (routine.kind === "check-in") { progress.lastCheckInAt = timestamp; progress.nextCheckInIndex += 1; }
  progress.updatedAt = timestamp; return progress;
}

/** Runs while the patient UI is open. It is a companionship scheduler, not clinical monitoring. */
export function createCareRoutineMonitor(options: {
  profileId: string;
  onDue(routine: DueCareRoutine): Promise<boolean> | boolean;
  store?: CareRoutineStore;
  now?: () => Date;
  pollMilliseconds?: number;
}): { start(): void; stop(): void; checkNow(): Promise<void> } {
  requireId(options.profileId); const store = options.store ?? deviceStorage; const now = options.now ?? (() => new Date());
  const pollMilliseconds = options.pollMilliseconds ?? 30_000;
  if (!Number.isFinite(pollMilliseconds) || pollMilliseconds < 1_000 || pollMilliseconds > 300_000) throw new Error("Routine polling interval must be between 1 and 300 seconds.");
  let timer: ReturnType<typeof setInterval> | null = null; let checking = false;
  const checkNow = async () => {
    if (checking) return; checking = true;
    try {
      const checkTime = now();
      const settings = validateCareRoutineSettings((await store.loadCareRoutineSettings(options.profileId)) ?? createDefaultCareRoutineSettings(options.profileId, checkTime));
      const storedProgress = await store.loadCareRoutineProgress(options.profileId);
      let progress = storedProgress ?? createCareRoutineProgress(options.profileId, checkTime);
      if (!storedProgress) await store.saveCareRoutineProgress(progress);
      for (const routine of careRoutinesDue(settings, progress, checkTime)) {
        if (await options.onDue(routine)) { progress = markCareRoutineDelivered(progress, routine, now()); await store.saveCareRoutineProgress(progress); }
      }
    } finally { checking = false; }
  };
  const checkWithoutUnhandledRejection = () => { void checkNow().catch(() => undefined); };
  return {
    start() { if (timer !== null) return; checkWithoutUnhandledRejection(); timer = setInterval(checkWithoutUnhandledRejection, pollMilliseconds); },
    stop() { if (timer !== null) clearInterval(timer); timer = null; },
    checkNow,
  };
}

function isRoutineDue(routine: RoutineDefinition, lastAt: string, now: Date): boolean { return routine.enabled && withinActiveWindow(routine, now) && now.getTime() - new Date(lastAt).getTime() >= routine.intervalMinutes * 60_000; }
function withinActiveWindow(routine: RoutineDefinition, now: Date): boolean {
  const current = now.getHours() * 60 + now.getMinutes(); const start = minutesFromClock(routine.activeFrom); const end = minutesFromClock(routine.activeUntil);
  if (start === end) return true; return start < end ? current >= start && current < end : current >= start || current < end;
}
function validateRoutine(routine: RoutineDefinition, minimum: number, maximum: number, label: string): void {
  if (typeof routine.enabled !== "boolean") throw new Error(`${label} enabled setting must be true or false.`);
  if (!Number.isSafeInteger(routine.intervalMinutes) || routine.intervalMinutes < minimum || routine.intervalMinutes > maximum) throw new Error(`${label} interval must be between ${minimum} and ${maximum} minutes.`);
  minutesFromClock(routine.activeFrom); minutesFromClock(routine.activeUntil);
}
function minutesFromClock(value: string): number { if (typeof value !== "string" || !CLOCK_TIME.test(value)) throw new Error("Active hours must use 24-hour HH:MM format."); const [hour, minute] = value.split(":").map(Number); return hour * 60 + minute; }
function cleanMessage(value: string, label: string): string { if (typeof value !== "string") throw new Error(`${label} must be text.`); const message = value.normalize("NFKC").trim(); if (!message || message.length > 240) throw new Error(`${label} must be 1–240 characters.`); return message; }
function requireId(value: string): string { if (typeof value !== "string" || !SAFE_ID.test(value)) throw new Error("Profile id is invalid."); return value; }
function requireDate(value: string, label: string): string { if (typeof value !== "string" || !Number.isFinite(Date.parse(value))) throw new Error(`${label} is invalid.`); return value; }
