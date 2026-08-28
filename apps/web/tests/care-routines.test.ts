import assert from "node:assert/strict";
import test from "node:test";

import {
  careRoutinesDue, createCareRoutineMonitor, createCareRoutineProgress, createDefaultCareRoutineSettings, markCareRoutineDelivered,
  type CareRoutineProgress, type CareRoutineSettings, type CareRoutineStore,
} from "../app/lib/care-routines";

const profileId = "local-profile";

test("hydration and check-ins become due on independent intervals", () => {
  const start = new Date(2026, 7, 22, 9, 0, 0); const settings = createDefaultCareRoutineSettings(profileId, start); const progress = createCareRoutineProgress(profileId, start);
  assert.deepEqual(careRoutinesDue(settings, progress, new Date(2026, 7, 22, 9, 59, 0)), []);
  assert.deepEqual(careRoutinesDue(settings, progress, new Date(2026, 7, 22, 10, 0, 0)).map((item) => item.kind), ["check-in"]);
  assert.deepEqual(careRoutinesDue(settings, progress, new Date(2026, 7, 22, 11, 0, 0)).map((item) => item.kind), ["hydration", "check-in"]);
});

test("delivery advances the check-in and active hours are respected", () => {
  const start = new Date(2026, 7, 22, 9, 0, 0); const settings = createDefaultCareRoutineSettings(profileId, start); let progress = createCareRoutineProgress(profileId, start);
  const first = careRoutinesDue(settings, progress, new Date(2026, 7, 22, 10, 0, 0))[0]; assert.equal(first.phraseId, "reassurance-1");
  progress = markCareRoutineDelivered(progress, first, new Date(2026, 7, 22, 10, 0, 0));
  assert.equal(careRoutinesDue(settings, progress, new Date(2026, 7, 22, 11, 0, 0)).find((item) => item.kind === "check-in")?.phraseId, "reassurance-2");
  assert.deepEqual(careRoutinesDue(settings, progress, new Date(2026, 7, 22, 23, 0, 0)), []);
});

test("monitor persists progress only after actual delivery", async () => {
  const now = new Date(2026, 7, 22, 11, 0, 0); const settings = createDefaultCareRoutineSettings(profileId, now); const earlier = new Date(2026, 7, 22, 8, 0, 0);
  let progress = createCareRoutineProgress(profileId, earlier); const saved: CareRoutineProgress[] = [];
  const store: CareRoutineStore = {
    loadCareRoutineSettings: async (): Promise<CareRoutineSettings> => settings, loadCareRoutineProgress: async () => progress,
    saveCareRoutineProgress: async (next) => { progress = next; saved.push(next); },
  };
  const delivered: string[] = [];
  const monitor = createCareRoutineMonitor({ profileId, store, now: () => now, onDue: async (routine) => { delivered.push(routine.kind); return routine.kind === "check-in"; } });
  await monitor.checkNow();
  assert.deepEqual(delivered, ["hydration", "check-in"]); assert.equal(saved.length, 1); assert.equal(progress.lastHydrationAt, earlier.toISOString()); assert.equal(progress.lastCheckInAt, now.toISOString());
});

test("monitor anchors a new schedule so reminders survive later polls", async () => {
  const now = new Date(2026, 7, 22, 9, 0, 0); const saved: CareRoutineProgress[] = [];
  const store: CareRoutineStore = {
    loadCareRoutineSettings: async () => createDefaultCareRoutineSettings(profileId, now), loadCareRoutineProgress: async () => saved.at(-1) ?? null,
    saveCareRoutineProgress: async (next) => { saved.push(next); },
  };
  const monitor = createCareRoutineMonitor({ profileId, store, now: () => now, onDue: async () => true });
  await monitor.checkNow();
  assert.equal(saved[0].lastHydrationAt, now.toISOString());
});
