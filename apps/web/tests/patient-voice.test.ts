import assert from "node:assert/strict";
import test from "node:test";

import {
  MAX_CAREGIVER_RECORDING_BYTES,
  createCaregiverPhraseRecording,
  createDefaultPatientSpeechSettings,
  createPatientSpeechService,
  selectSystemVoice,
  type CaregiverPhraseRecording,
  type PatientSpeechDependencies,
} from "../app/lib/patient-voice";

function recording(overrides: Partial<Parameters<typeof createCaregiverPhraseRecording>[0]> = {}): CaregiverPhraseRecording {
  return createCaregiverPhraseRecording({
    profileId: "local-profile", kind: "gesture", phraseId: "water", phraseSnapshot: "I need water, please.", caregiverName: "Maya",
    audio: new Blob([new Uint8Array(1_000)], { type: "audio/webm;codecs=opus" }), durationMs: 1_200, caregiverConfirmed: true, ...overrides,
  }, new Date("2026-08-22T10:00:00.000Z"));
}

test("caregiver recordings require confirmation and enforce local audio bounds", () => {
  assert.throws(() => recording({ caregiverConfirmed: false }), /caregiver must confirm/i);
  assert.throws(() => recording({ audio: new Blob(["not audio"], { type: "text/plain" }) }), /supported browser microphone/i);
  assert.throws(() => recording({ durationMs: 16_000 }), /duration/i);
  assert.throws(() => recording({ audio: new Blob([new Uint8Array(MAX_CAREGIVER_RECORDING_BYTES + 1)], { type: "audio/webm" }) }), /no larger/i);
  const value = recording(); assert.equal(value.source, "caregiver-microphone"); assert.equal(value.mimeType, "audio/webm"); assert.equal(value.audio.size, 1_000);
});

test("the selected voice wins, with a local language fallback", () => {
  const settings = createDefaultPatientSpeechSettings("local-profile");
  const voices = [{ voiceURI: "local-bn", lang: "bn-BD", localService: true }, { voiceURI: "selected", lang: "en-US", localService: false }];
  settings.preferredVoiceUri = "selected"; assert.equal(selectSystemVoice(voices, settings)?.voiceURI, "selected");
  settings.preferredVoiceUri = null; settings.language = "bn-BD"; assert.equal(selectSystemVoice(voices, settings)?.voiceURI, "local-bn");
});

test("patient speech plays a caregiver recording first", async () => {
  const calls: string[] = []; const saved = recording();
  const dependencies: PatientSpeechDependencies = {
    loadSettings: async () => createDefaultPatientSpeechSettings("local-profile"), loadRecording: async () => saved,
    playRecording: async () => { calls.push("recording"); }, listSystemVoices: () => [{ voiceURI: "local", lang: "en-US", localService: true }],
    speakWithSystemVoice: async () => { calls.push("system"); },
  };
  const result = await createPatientSpeechService(dependencies).speak({ profileId: "local-profile", kind: "gesture", phraseId: "water", text: "I need water, please.", caregiverName: "Maya" });
  assert.deepEqual(calls, ["recording"]); assert.equal(result.method, "caregiver-recording"); assert.equal(result.spoken, true);
});

test("unplayable recorded audio falls back immediately to system speech", async () => {
  const calls: string[] = [];
  const dependencies: PatientSpeechDependencies = {
    loadSettings: async () => createDefaultPatientSpeechSettings("local-profile"), loadRecording: async () => recording(),
    playRecording: async () => { throw new Error("decode failed"); }, listSystemVoices: () => [{ voiceURI: "local", lang: "en-US", localService: true }],
    speakWithSystemVoice: async () => { calls.push("system"); },
  };
  const result = await createPatientSpeechService(dependencies).speak({ profileId: "local-profile", kind: "gesture", phraseId: "water", text: "I need water, please.", caregiverName: "Maya" });
  assert.deepEqual(calls, ["system"]); assert.equal(result.method, "system-voice");
});

test("a recording for stale phrase text is never played", async () => {
  const calls: string[] = [];
  const dependencies: PatientSpeechDependencies = {
    loadSettings: async () => createDefaultPatientSpeechSettings("local-profile"), loadRecording: async () => recording(),
    playRecording: async () => { calls.push("recording"); }, listSystemVoices: () => [{ voiceURI: "local", lang: "en-US", localService: true }],
    speakWithSystemVoice: async () => { calls.push("system"); },
  };
  await createPatientSpeechService(dependencies).speak({ profileId: "local-profile", kind: "gesture", phraseId: "water", text: "Please call my caregiver.", caregiverName: "Maya" });
  assert.deepEqual(calls, ["system"]);
});

test("device-storage failure never blocks immediate system speech", async () => {
  const calls: string[] = [];
  const dependencies: PatientSpeechDependencies = {
    loadSettings: async () => { throw new Error("indexedDB unavailable"); },
    loadRecording: async () => { throw new Error("indexedDB unavailable"); },
    playRecording: async () => { calls.push("recording"); },
    listSystemVoices: () => [{ voiceURI: "local", lang: "en-US", localService: true }],
    speakWithSystemVoice: async () => { calls.push("system"); },
  };
  const result = await createPatientSpeechService(dependencies).speak({ profileId: "local-profile", kind: "gesture", phraseId: "water", text: "I need water, please." });
  assert.deepEqual(calls, ["system"]);
  assert.equal(result.spoken, true);
});

test("a newer phrase interrupts old recorded playback without an old-voice fallback", async () => {
  let playbackCount = 0;
  let rejectActive: ((reason: Error) => void) | null = null;
  const dependencies: PatientSpeechDependencies = {
    loadSettings: async () => createDefaultPatientSpeechSettings("local-profile"),
    loadRecording: async () => recording(),
    playRecording: async () => {
      playbackCount += 1;
      if (playbackCount === 1) await new Promise<void>((_resolve, reject) => { rejectActive = reject; });
    },
    listSystemVoices: () => [{ voiceURI: "local", lang: "en-US", localService: true }],
    speakWithSystemVoice: async () => undefined,
    cancelPlayback: () => { rejectActive?.(new Error("interrupted")); rejectActive = null; },
  };
  const speech = createPatientSpeechService(dependencies);
  const first = speech.speak({ profileId: "local-profile", kind: "gesture", phraseId: "water", text: "I need water, please.", caregiverName: "Maya" });
  while (playbackCount === 0) await new Promise((resolve) => setTimeout(resolve, 0));
  const second = speech.speak({ profileId: "local-profile", kind: "gesture", phraseId: "water", text: "I need water, please.", caregiverName: "Maya" });
  assert.equal((await first).spoken, false);
  assert.equal((await second).method, "caregiver-recording");
  assert.equal(playbackCount, 2);
});

test("caregiver audio plays only for the currently configured caregiver", async () => {
  const calls: string[] = [];
  const dependencies: PatientSpeechDependencies = {
    loadSettings: async () => createDefaultPatientSpeechSettings("local-profile"), loadRecording: async () => recording(),
    playRecording: async () => { calls.push("recording"); }, listSystemVoices: () => [{ voiceURI: "local", lang: "en-US", localService: true }],
    speakWithSystemVoice: async () => { calls.push("system"); },
  };
  const speech = createPatientSpeechService(dependencies);
  const request = { profileId: "local-profile", kind: "gesture" as const, phraseId: "water", text: "I need water, please." };
  assert.equal((await speech.speak({ ...request, caregiverName: "Another caregiver" })).method, "system-voice");
  assert.equal((await speech.speak(request)).method, "system-voice");
  assert.deepEqual(calls, ["system", "system"]);
});
