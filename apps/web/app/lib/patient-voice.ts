import { deviceStorage } from "./storage";

export const MAX_CAREGIVER_RECORDING_BYTES = 4 * 1024 * 1024;
export const MIN_CAREGIVER_RECORDING_DURATION_MS = 300;
export const MAX_CAREGIVER_RECORDING_DURATION_MS = 15_000;
export const CAREGIVER_RECORDING_MIME_TYPES = ["audio/webm", "audio/ogg", "audio/mp4", "audio/mpeg", "audio/wav"] as const;

const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$/;
const LANGUAGE_TAG = /^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/;

export type PhraseAudioKind = "gesture" | "hydration" | "check-in";
export type SpeechPreference = "caregiver-recording-first" | "system-voice";

export type PatientSpeechSettings = {
  id: string;
  profileId: string;
  preference: SpeechPreference;
  preferredVoiceUri: string | null;
  language: string;
  rate: number;
  pitch: number;
  volume: number;
  updatedAt: string;
};

/** A short caregiver microphone capture. It is not an upload or a voice-cloning input. */
export type CaregiverPhraseRecording = {
  id: string;
  profileId: string;
  kind: PhraseAudioKind;
  phraseId: string;
  phraseSnapshot: string;
  caregiverName: string;
  source: "caregiver-microphone";
  audio: Blob;
  mimeType: string;
  byteLength: number;
  durationMs: number;
  recordedAt: string;
};

export type CaregiverRecordingDraft = {
  profileId: string;
  kind: PhraseAudioKind;
  phraseId: string;
  phraseSnapshot: string;
  caregiverName: string;
  audio: Blob;
  durationMs: number;
  /** The UI must obtain this explicit confirmation before local storage. */
  caregiverConfirmed: boolean;
};

export type CapturedCaregiverAudio = { audio: Blob; durationMs: number };
export type ActiveCaregiverMicrophoneCapture = {
  /** Stops the current microphone capture and returns the bounded audio. */
  stop(): Promise<CapturedCaregiverAudio>;
  /** Stops without producing a recording. */
  cancel(): void;
};

export type PatientPhraseRequest = { profileId: string; kind: PhraseAudioKind; phraseId: string; text: string; caregiverName?: string };
export type PatientSpeechResult = { method: "caregiver-recording" | "system-voice" | "caption-only"; spoken: boolean; message: string };
export type SystemVoiceDescriptor = { voiceURI: string; lang: string; localService: boolean };
export type PatientSpeechDependencies = {
  loadSettings(profileId: string): Promise<PatientSpeechSettings | null>;
  loadRecording(profileId: string, kind: PhraseAudioKind, phraseId: string): Promise<CaregiverPhraseRecording | null>;
  playRecording(recording: CaregiverPhraseRecording): Promise<void>;
  listSystemVoices(): ReadonlyArray<SystemVoiceDescriptor>;
  speakWithSystemVoice(text: string, voiceUri: string, settings: PatientSpeechSettings): Promise<void>;
  cancelPlayback?(): void;
};

export function patientSpeechSettingsId(profileId: string): string {
  return `patient-speech:${requireId(profileId, "profile id")}`;
}

export function caregiverPhraseRecordingId(profileId: string, kind: PhraseAudioKind, phraseId: string): string {
  return `caregiver-audio:${requireId(profileId, "profile id")}:${requireKind(kind)}:${requireId(phraseId, "phrase id")}`;
}

export function createDefaultPatientSpeechSettings(profileId: string, now = new Date()): PatientSpeechSettings {
  requireId(profileId, "profile id");
  return {
    id: patientSpeechSettingsId(profileId), profileId, preference: "caregiver-recording-first",
    preferredVoiceUri: null, language: "en-US", rate: 1.0, pitch: 1.0, volume: 1, updatedAt: now.toISOString(),
  };
}

export function validatePatientSpeechSettings(value: PatientSpeechSettings): PatientSpeechSettings {
  requireId(value.profileId, "profile id");
  if (value.id !== patientSpeechSettingsId(value.profileId)) throw new Error("Patient speech settings do not match the profile.");
  if (value.preference !== "caregiver-recording-first" && value.preference !== "system-voice") throw new Error("Speech preference is invalid.");
  if (value.preferredVoiceUri !== null && (typeof value.preferredVoiceUri !== "string" || value.preferredVoiceUri.length > 240)) throw new Error("Preferred voice identifier is invalid.");
  if (!LANGUAGE_TAG.test(value.language)) throw new Error("Speech language must be a valid language tag.");
  requireRange(value.rate, 0.5, 2, "Speech rate");
  requireRange(value.pitch, 0, 2, "Speech pitch");
  requireRange(value.volume, 0, 1, "Speech volume");
  requireDate(value.updatedAt, "Speech settings timestamp");
  return structuredClone(value);
}

export function createCaregiverPhraseRecording(draft: CaregiverRecordingDraft, now = new Date()): CaregiverPhraseRecording {
  if (draft.caregiverConfirmed !== true) throw new Error("The caregiver must confirm that this is their own microphone recording.");
  requireId(draft.profileId, "profile id");
  requireId(draft.phraseId, "phrase id");
  requireKind(draft.kind);
  const phraseSnapshot = cleanText(draft.phraseSnapshot, 240, "Phrase");
  const caregiverName = cleanText(draft.caregiverName, 80, "Caregiver name");
  const mimeType = normalizeMimeType(draft.audio.type);
  if (!CAREGIVER_RECORDING_MIME_TYPES.includes(mimeType as (typeof CAREGIVER_RECORDING_MIME_TYPES)[number])) throw new Error("Use a supported browser microphone recording format.");
  if (draft.audio.size <= 0 || draft.audio.size > MAX_CAREGIVER_RECORDING_BYTES) throw new Error(`Caregiver recordings must be no larger than ${MAX_CAREGIVER_RECORDING_BYTES} bytes.`);
  requireRange(draft.durationMs, MIN_CAREGIVER_RECORDING_DURATION_MS, MAX_CAREGIVER_RECORDING_DURATION_MS, "Recording duration");
  return {
    id: caregiverPhraseRecordingId(draft.profileId, draft.kind, draft.phraseId), profileId: draft.profileId,
    kind: draft.kind, phraseId: draft.phraseId, phraseSnapshot, caregiverName, source: "caregiver-microphone",
    audio: draft.audio, mimeType, byteLength: draft.audio.size, durationMs: Math.round(draft.durationMs), recordedAt: now.toISOString(),
  };
}

/** Captures directly from the caregiver microphone; no upload or synthesis path is accepted. */
export async function startCaregiverMicrophoneCapture(): Promise<ActiveCaregiverMicrophoneCapture> {
  if (typeof navigator === "undefined" || !navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === "undefined") {
    throw new Error("Microphone recording is unavailable in this browser.");
  }
  const stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true }, video: false });
  const preferredType = CAREGIVER_RECORDING_MIME_TYPES.find((mimeType) => MediaRecorder.isTypeSupported(mimeType));
  let recorder: MediaRecorder;
  try {
    recorder = preferredType ? new MediaRecorder(stream, { mimeType: preferredType }) : new MediaRecorder(stream);
  } catch (error) {
    stream.getTracks().forEach((track) => track.stop());
    throw error;
  }

  const chunks: Blob[] = [];
  const waiters: Array<{ resolve(value: CapturedCaregiverAudio): void; reject(reason: Error): void }> = [];
  const startedAt = Date.now();
  let byteLength = 0;
  let outcome: CapturedCaregiverAudio | Error | null = null;
  let cancelled = false;
  let oversized = false;
  let timeout: ReturnType<typeof setTimeout> | null = null;

  const stopTracks = () => stream.getTracks().forEach((track) => track.stop());
  const settle = (value: CapturedCaregiverAudio | Error) => {
    if (outcome) return;
    outcome = value;
    for (const waiter of waiters.splice(0)) {
      if (value instanceof Error) waiter.reject(value);
      else waiter.resolve(value);
    }
  };
  const stopRecorder = () => { if (recorder.state !== "inactive") recorder.stop(); };

  recorder.ondataavailable = (event) => {
    if (!event.data.size) return;
    byteLength += event.data.size;
    if (byteLength > MAX_CAREGIVER_RECORDING_BYTES) {
      oversized = true;
      stopRecorder();
      return;
    }
    chunks.push(event.data);
  };
  recorder.onerror = () => {
    if (timeout !== null) clearTimeout(timeout);
    settle(new Error("The caregiver microphone recording failed."));
    stopRecorder();
    stopTracks();
  };
  recorder.onstop = () => {
    if (timeout !== null) clearTimeout(timeout);
    stopTracks();
    if (cancelled) { settle(new Error("Caregiver recording was cancelled.")); return; }
    if (oversized) { settle(new Error(`Caregiver recordings must be no larger than ${MAX_CAREGIVER_RECORDING_BYTES} bytes.`)); return; }
    const mimeType = recorder.mimeType || chunks[0]?.type || preferredType || "";
    const audio = new Blob(chunks, { type: mimeType });
    const durationMs = Math.min(MAX_CAREGIVER_RECORDING_DURATION_MS, Date.now() - startedAt);
    if (audio.size <= 0 || durationMs < MIN_CAREGIVER_RECORDING_DURATION_MS) { settle(new Error("Hold record for at least a moment before stopping.")); return; }
    settle({ audio, durationMs });
  };
  try {
    recorder.start(250);
  } catch (error) {
    stopTracks();
    throw error;
  }
  timeout = setTimeout(stopRecorder, MAX_CAREGIVER_RECORDING_DURATION_MS);

  return {
    stop() {
      if (outcome instanceof Error) return Promise.reject(outcome);
      if (outcome) return Promise.resolve(outcome);
      return new Promise<CapturedCaregiverAudio>((resolve, reject) => { waiters.push({ resolve, reject }); stopRecorder(); });
    },
    cancel() { if (outcome) return; cancelled = true; stopRecorder(); stopTracks(); },
  };
}

export async function saveLocalCaregiverPhraseRecording(draft: CaregiverRecordingDraft): Promise<CaregiverPhraseRecording> {
  const recording = createCaregiverPhraseRecording(draft);
  await deviceStorage.saveCaregiverPhraseRecording(recording);
  return recording;
}

export async function saveLocalPatientSpeechSettings(settings: PatientSpeechSettings): Promise<PatientSpeechSettings> {
  const validated = validatePatientSpeechSettings(settings);
  await deviceStorage.savePatientSpeechSettings(validated);
  return validated;
}

export function validateStoredCaregiverRecording(value: CaregiverPhraseRecording): CaregiverPhraseRecording {
  if (value.source !== "caregiver-microphone") throw new Error("Only direct caregiver microphone recordings are supported.");
  const validated = createCaregiverPhraseRecording({
    profileId: value.profileId, kind: value.kind, phraseId: value.phraseId, phraseSnapshot: value.phraseSnapshot,
    caregiverName: value.caregiverName, audio: value.audio, durationMs: value.durationMs, caregiverConfirmed: true,
  }, new Date(requireDate(value.recordedAt, "Recording timestamp")));
  if (value.id !== validated.id || value.byteLength !== validated.byteLength || normalizeMimeType(value.mimeType) !== validated.mimeType) throw new Error("Stored caregiver recording metadata is inconsistent.");
  return validated;
}

export function selectSystemVoice(voices: ReadonlyArray<SystemVoiceDescriptor>, settings: PatientSpeechSettings): SystemVoiceDescriptor | null {
  if (settings.preferredVoiceUri) {
    const preferred = voices.find((voice) => voice.voiceURI === settings.preferredVoiceUri);
    if (preferred) return preferred;
  }
  const language = settings.language.toLocaleLowerCase("en-US");
  const isSamantha = (name: string) => name.toLowerCase().includes("samantha");
  const femaleMatch = (name: string) => /(samantha|female|zira|karen|victoria|eva|jenny|aria|sfg)/i.test(name);

  return voices.find((voice) => isSamantha(voice.voiceURI))
    ?? voices.find((voice) => voice.localService && isSamantha(voice.voiceURI))
    ?? voices.find((voice) => voice.localService && voice.lang.toLocaleLowerCase("en-US") === language && femaleMatch(voice.voiceURI))
    ?? voices.find((voice) => voice.localService && voice.lang.toLocaleLowerCase("en-US") === language)
    ?? voices.find((voice) => voice.lang.toLocaleLowerCase("en-US") === language && femaleMatch(voice.voiceURI))
    ?? voices.find((voice) => voice.localService && voice.lang.toLocaleLowerCase("en-US").startsWith(language.split("-")[0]))
    ?? voices.find((voice) => voice.localService)
    ?? voices[0]
    ?? null;
}

export function createPatientSpeechService(dependencies: PatientSpeechDependencies = browserSpeechDependencies): { speak(request: PatientPhraseRequest): Promise<PatientSpeechResult>; stop(): void } {
  let requestSequence = 0;
  const interrupted = (): PatientSpeechResult => ({ method: "caption-only", spoken: false, message: "A newer phrase replaced this playback." });
  return {
    async speak(request) {
      const requestId = ++requestSequence;
      dependencies.cancelPlayback?.();
      requireId(request.profileId, "profile id"); requireId(request.phraseId, "phrase id"); requireKind(request.kind);
      const text = cleanText(request.text, 500, "Spoken phrase");
      const expectedCaregiverName = typeof request.caregiverName === "string" && request.caregiverName.trim()
        ? cleanText(request.caregiverName, 80, "Caregiver name")
        : null;
      let settings = createDefaultPatientSpeechSettings(request.profileId);
      try {
        const saved = await dependencies.loadSettings(request.profileId);
        if (saved) settings = validatePatientSpeechSettings(saved);
      } catch { /* Device storage must never block immediate speech. */ }
      if (requestId !== requestSequence) return interrupted();
      if (settings.preference === "caregiver-recording-first" && expectedCaregiverName) {
        let stored: CaregiverPhraseRecording | null = null;
        try { stored = await dependencies.loadRecording(request.profileId, request.kind, request.phraseId); } catch { /* Use system speech when local audio storage is unavailable. */ }
        if (requestId !== requestSequence) return interrupted();
        if (stored) {
          try {
            const recording = validateStoredCaregiverRecording(stored);
            if (recording.phraseSnapshot !== text) throw new Error("The saved recording belongs to an older phrase.");
            if (recording.caregiverName !== expectedCaregiverName) throw new Error("The saved recording belongs to another caregiver.");
            await dependencies.playRecording(recording);
            if (requestId !== requestSequence) return interrupted();
            return { method: "caregiver-recording", spoken: true, message: `Played ${recording.caregiverName}’s local recording.` };
          } catch {
            if (requestId !== requestSequence) return interrupted();
            // Fall back immediately when local audio is damaged or cannot play.
          }
        }
      }
      const voice = selectSystemVoice(dependencies.listSystemVoices(), settings);
      if (!voice) return { method: "caption-only", spoken: false, message: "No usable system voice is installed; the phrase remains visible." };
      try {
        await dependencies.speakWithSystemVoice(text, voice.voiceURI, settings);
        if (requestId !== requestSequence) return interrupted();
        return { method: "system-voice", spoken: true, message: "Spoken with the selected device voice." };
      } catch {
        if (requestId !== requestSequence) return interrupted();
        return { method: "caption-only", spoken: false, message: "Voice playback failed; the phrase remains visible." };
      }
    },
    stop() { requestSequence += 1; dependencies.cancelPlayback?.(); },
  };
}

let activeAudio: HTMLAudioElement | null = null;
let cancelActiveAudio: (() => void) | null = null;
let cancelActiveSystemSpeech: (() => void) | null = null;

function cancelBrowserPlayback(): void {
  cancelActiveAudio?.();
  cancelActiveAudio = null;
  cancelActiveSystemSpeech?.();
  cancelActiveSystemSpeech = null;
  if (typeof window !== "undefined" && "speechSynthesis" in window) window.speechSynthesis.cancel();
}

const browserSpeechDependencies: PatientSpeechDependencies = {
  loadSettings: (profileId) => deviceStorage.loadPatientSpeechSettings(profileId),
  loadRecording: (profileId, kind, phraseId) => deviceStorage.loadCaregiverPhraseRecording(profileId, kind, phraseId),
  async playRecording(recording) {
    if (typeof Audio === "undefined" || typeof URL.createObjectURL !== "function") throw new Error("Recorded audio playback is unavailable.");
    const url = URL.createObjectURL(recording.audio); const audio = new Audio(url); activeAudio = audio;
    try {
      await new Promise<void>((resolve, reject) => {
        let settled = false;
        const finish = (error?: Error) => {
          if (settled) return;
          settled = true;
          if (error) reject(error); else resolve();
        };
        cancelActiveAudio = () => { audio.pause(); finish(new Error("Recorded playback was interrupted.")); };
        audio.onended = () => finish(); audio.onerror = () => finish(new Error("Playback failed.")); void audio.play().catch((error: unknown) => finish(error instanceof Error ? error : new Error("Playback failed.")));
      });
    } finally {
      if (activeAudio === audio) activeAudio = null;
      cancelActiveAudio = null;
      URL.revokeObjectURL(url);
    }
  },
  listSystemVoices() { return typeof window !== "undefined" && "speechSynthesis" in window ? window.speechSynthesis.getVoices() : []; },
  speakWithSystemVoice(text, voiceUri, settings) {
    return new Promise<void>((resolve, reject) => {
      if (typeof window === "undefined" || !("speechSynthesis" in window)) { reject(new Error("System speech is unavailable.")); return; }
      const voice = window.speechSynthesis.getVoices().find((candidate) => candidate.voiceURI === voiceUri);
      if (!voice) { reject(new Error("The selected system voice is unavailable.")); return; }
      window.speechSynthesis.cancel(); const utterance = new SpeechSynthesisUtterance(text);
      utterance.voice = voice; utterance.lang = settings.language; utterance.rate = settings.rate; utterance.pitch = settings.pitch; utterance.volume = settings.volume;
      let settled = false;
      const finish = (error?: Error) => {
        if (settled) return;
        settled = true;
        cancelActiveSystemSpeech = null;
        if (error) reject(error); else resolve();
      };
      cancelActiveSystemSpeech = () => finish(new Error("System speech was interrupted."));
      utterance.onend = () => finish(); utterance.onerror = () => finish(new Error("System speech failed.")); window.speechSynthesis.speak(utterance);
    });
  },
  cancelPlayback: cancelBrowserPlayback,
};

function normalizeMimeType(value: string): string { return value.split(";", 1)[0].trim().toLocaleLowerCase("en-US"); }
function requireKind(value: PhraseAudioKind): PhraseAudioKind { if (value !== "gesture" && value !== "hydration" && value !== "check-in") throw new Error("Phrase audio kind is invalid."); return value; }
function requireId(value: string, label: string): string { if (typeof value !== "string" || !SAFE_ID.test(value)) throw new Error(`${label} is invalid.`); return value; }
function cleanText(value: string, maximum: number, label: string): string { if (typeof value !== "string") throw new Error(`${label} must be text.`); const cleaned = value.normalize("NFKC").trim(); if (!cleaned || cleaned.length > maximum) throw new Error(`${label} must be 1–${maximum} characters.`); return cleaned; }
function requireRange(value: number, minimum: number, maximum: number, label: string): number { if (!Number.isFinite(value) || value < minimum || value > maximum) throw new Error(`${label} must be between ${minimum} and ${maximum}.`); return value; }
function requireDate(value: string, label: string): string { if (typeof value !== "string" || !Number.isFinite(Date.parse(value))) throw new Error(`${label} is invalid.`); return value; }
