"use client";

import type { HandLandmarker } from "@mediapipe/tasks-vision";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { AshaAvatar } from "./AshaAvatar";
import { AshaCompanion } from "./AshaCompanion";
import { PiDisplayView } from "./PiDisplayView";
import { usePiDevice } from "../hooks/usePiDevice";
import {
  caregiverSocketUrl,
  checkApi,
  detachRemoteProfile,
  endRemoteSession,
  flushOutbox,
  flushPendingConsentUpdates,
  grantCaregiver,
  loadCaregiverAlerts,
  loadRemoteDevices,
  sendEvent,
  sendRemoteDeviceCaption,
  syncRemoteProfile,
  updateCaregiverAlert,
  type CaregiverAlert,
  type RemoteDevice,
} from "../lib/api";
import {
  CONFIDENCE_THRESHOLD,
  createDefaultProfile,
  flattenLandmarks,
  parseProfile,
  predictPrototype,
  profileModelFingerprint,
  resampleSequence,
  trainPrototypeModel,
  type FingerSpeakProfile,
  type Gesture,
  type PrototypeModel,
  type TimedRawFrame,
} from "../lib/fingerspeak";
import { IntentMachine, type IntentOutput } from "../lib/intent-machine";
import { importPrototypeBundle } from "../lib/model-bundle";
import { dialablePhone } from "../lib/asha-companion";
import { deviceStorage, type LocalContactSettings, type OutboxEvent } from "../lib/storage";

type View = "speak" | "pi-display" | "calibrate" | "caregiver";
type CameraStatus = "off" | "loading" | "ready" | "error";

type SpokenEntry = {
  id: string;
  phrase: string;
  gesture: string;
  risk: Gesture["risk"];
  at: string;
  source: "gesture" | "touch";
};

const HAND_CONNECTIONS = [
  [0, 1], [1, 2], [2, 3], [3, 4],
  [0, 5], [5, 6], [6, 7], [7, 8],
  [5, 9], [9, 10], [10, 11], [11, 12],
  [9, 13], [13, 14], [14, 15], [15, 16],
  [13, 17], [17, 18], [18, 19], [19, 20], [0, 17],
] as const;

const EMPTY_CONTACT_SETTINGS: LocalContactSettings = {
  id: "local-contact-settings",
  caregiverName: "",
  caregiverPhone: "",
  patientPhone: "",
  updatedAt: "",
};

function formatPercent(value: number | null): string {
  return value === null ? "Unknown" : `${value}%`;
}

function eventId(): string {
  const webCrypto: Crypto | undefined = typeof globalThis.crypto === "undefined" ? undefined : globalThis.crypto;
  if (typeof webCrypto?.randomUUID === "function") return webCrypto.randomUUID();
  const bytes = new Uint8Array(16);
  if (webCrypto) webCrypto.getRandomValues(bytes);
  else for (let index = 0; index < bytes.length; index += 1) bytes[index] = Math.floor(Math.random() * 256);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0"));
  return `${hex.slice(0, 4).join("")}-${hex.slice(4, 6).join("")}-${hex.slice(6, 8).join("")}-${hex.slice(8, 10).join("")}-${hex.slice(10).join("")}`;
}

export function FingerSpeakApp() {
  const piDevice = usePiDevice();
  const [view, setView] = useState<View>("speak");
  const [profile, setProfile] = useState<FingerSpeakProfile>(() => createDefaultProfile());
  const [model, setModel] = useState<PrototypeModel | null>(null);
  const [cameraStatus, setCameraStatus] = useState<CameraStatus>("off");
  const [cameraMessage, setCameraMessage] = useState("Camera is off. Touch controls remain available.");
  const [tracking, setTracking] = useState(false);
  const [captureTarget, setCaptureTarget] = useState<string | null>(null);
  const [captureMessage, setCaptureMessage] = useState("Capture two clear examples of each movement.");
  const [prediction, setPrediction] = useState({ gestureId: null as string | null, confidence: 0, inDistribution: false });
  const [intent, setIntent] = useState<IntentOutput>(() => new IntentMachine().snapshot());
  const [voiceMessage, setVoiceMessage] = useState("Ready to speak.");
  const [spoken, setSpoken] = useState<SpokenEntry[]>([]);
  const [armedGestureId, setArmedGestureId] = useState<string | null>(null);
  const [serverOnline, setServerOnline] = useState(false);
  const [alerts, setAlerts] = useState<CaregiverAlert[]>([]);
  const [remoteProfileId, setRemoteProfileId] = useState<string | null>(null);
  const [caregiverProfileId, setCaregiverProfileId] = useState<string | null>(null);
  const [caregiverProfileInput, setCaregiverProfileInput] = useState("");
  const [caregiverSubject, setCaregiverSubject] = useState("");
  const [caregiverMessage, setCaregiverMessage] = useState("Enter an authorized profile ID to use this dashboard on another device.");
  const [socketStatus, setSocketStatus] = useState<"offline" | "connecting" | "live">("offline");
  const [falseActivations, setFalseActivations] = useState(0);
  const [missedGestures, setMissedGestures] = useState(0);
  const [localContacts, setLocalContacts] = useState<LocalContactSettings>(EMPTY_CONTACT_SETTINGS);
  const [contactDraft, setContactDraft] = useState<LocalContactSettings>(EMPTY_CONTACT_SETTINGS);
  const [localSettingsMessage, setLocalSettingsMessage] = useState("Phone numbers and the Pi pairing token stay only on this device.");
  const [piEndpointDraft, setPiEndpointDraft] = useState("");
  const [piPairingTokenDraft, setPiPairingTokenDraft] = useState("");
  const [caregiverOutboundMessage, setCaregiverOutboundMessage] = useState("");
  const [caregiverActionMessage, setCaregiverActionMessage] = useState("Calls use the phone dialer. Messages require a paired Pi.");
  const [remoteDevices, setRemoteDevices] = useState<RemoteDevice[]>([]);
  const [remoteDeviceMessage, setRemoteDeviceMessage] = useState("No verified patient-device heartbeat yet.");

  const videoRef = useRef<HTMLVideoElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const modelInputRef = useRef<HTMLInputElement>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const landmarkerRef = useRef<HandLandmarker | null>(null);
  const animationRef = useRef<number | null>(null);
  const processFrameRef = useRef<() => void>(() => undefined);
  const recentFramesRef = useRef<TimedRawFrame[]>([]);
  const captureFramesRef = useRef<TimedRawFrame[]>([]);
  const capturingRef = useRef(false);
  const captureTimerRef = useRef<number | null>(null);
  const captureTokenRef = useRef(0);
  const lastInferenceRef = useRef(0);
  const modelRef = useRef<PrototypeModel | null>(null);
  const profileRef = useRef(profile);
  const machineRef = useRef(new IntentMachine(CONFIDENCE_THRESHOLD, 5));
  const armedTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const currentGesture = useMemo(
    () => profile.gestures.find((gesture) => gesture.id === prediction.gestureId) ?? null,
    [prediction.gestureId, profile.gestures],
  );
  const calibrationReady = profile.gestures.every((gesture) => gesture.samples.length >= 2);
  const capturedCount = profile.gestures.reduce((total, gesture) => total + gesture.samples.length, 0);
  const requiredCount = profile.gestures.length * 2;
  const patientContext = useMemo<Record<string, unknown>>(() => ({
    ...(remoteProfileId ? { profile_id: remoteProfileId } : {}),
    care_mode: "communication",
    current_activity: piDevice.telemetry.tracking ? "Using gesture tracking" : "Using phone communication",
    wheelchair_status: "unknown",
    trusted_contact_available: Boolean(dialablePhone(localContacts.caregiverPhone)),
  }), [localContacts.caregiverPhone, piDevice.telemetry.tracking, remoteProfileId]);
  const caregiverRemotePi = useMemo(
    () => remoteDevices.find((device) => device.enabled) ?? null,
    [remoteDevices],
  );
  const caregiverDeviceOnline = piDevice.status === "connected" || caregiverRemotePi?.online === true;
  const caregiverDeviceState = caregiverRemotePi?.last_state ?? null;

  useEffect(() => {
    profileRef.current = profile;
  }, [profile]);

  useEffect(() => {
    modelRef.current = model;
  }, [model]);

  useEffect(() => {
    let cancelled = false;
    void deviceStorage.loadLocalContactSettings().then((saved) => {
      if (cancelled || !saved) return;
      setLocalContacts(saved);
      setContactDraft(saved);
    }).catch(() => {
      if (!cancelled) setLocalSettingsMessage("Local contact storage is unavailable. No phone number was loaded.");
    });
    return () => { cancelled = true; };
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      setPiEndpointDraft(piDevice.endpoint);
      setPiPairingTokenDraft(piDevice.pairingToken);
    }, 0);
    return () => window.clearTimeout(timer);
  }, [piDevice.endpoint, piDevice.pairingToken]);

  useEffect(() => {
    let cancelled = false;
    void Promise.all([
      deviceStorage.loadProfile("local-profile"),
      deviceStorage.loadModel("local-profile"),
      deviceStorage.loadRemoteLink(),
      deviceStorage.loadConsentGuard("local-profile"),
    ]).then(async ([savedProfile, savedModel, savedLink, consentGuard]) => {
      if (cancelled) return;
      let restoredProfile = createDefaultProfile();
      if (savedProfile) {
        try {
          restoredProfile = parseProfile(savedProfile, { preserveLocalConsent: true });
          if (consentGuard) {
            restoredProfile = {
              ...restoredProfile,
              consentToEventSync: restoredProfile.consentToEventSync && !consentGuard.eventSyncDenied,
              consentToCaregiverAlerts: restoredProfile.consentToCaregiverAlerts && !consentGuard.caregiverAlertsDenied,
            };
          }
          setProfile(restoredProfile);
        } catch {
          setCaptureMessage("A saved profile was incompatible, so a safe default was restored.");
        }
      }
      const expectedFingerprint = await profileModelFingerprint(restoredProfile);
      const expectedGestureIds = restoredProfile.gestures.map((gesture) => gesture.id);
      const savedGestureIds = savedModel?.prototypes?.map((prototype) => prototype.gestureId) ?? [];
      const validSavedModel =
        savedModel?.featureVersion === "3d-angle-motion-v1" &&
        savedModel.sequenceLength === 20 &&
        savedModel.featureLength === 98 &&
        savedModel.profileFingerprint === expectedFingerprint &&
        expectedGestureIds.length === savedGestureIds.length &&
        expectedGestureIds.every((id, index) => id === savedGestureIds[index]) &&
        savedModel.prototypes.every((prototype) => prototype.centroid.length === 196 && prototype.centroid.every(Number.isFinite) && Number.isFinite(prototype.spread) && prototype.spread >= 0.05);
      if (validSavedModel) {
        setModel(savedModel);
      } else if (savedModel) {
        await deviceStorage.deleteModel("local-profile");
        setCaptureMessage("A stale or incompatible edge model was removed. Recalibrate or import its matching bundle.");
      }
      if (savedLink?.localProfileId === restoredProfile.id) {
        setRemoteProfileId(savedLink.profileId);
        setCaregiverProfileId((current) => current ?? savedLink.profileId);
        setCaregiverProfileInput((current) => current || savedLink.profileId);
      }
    }).catch(() => {
      if (!cancelled) setCaptureMessage("Device storage is unavailable. Cloud sharing remains off and changes cannot be saved until storage is restored.");
    });
    return () => { cancelled = true; };
  }, []);

  useEffect(() => {
    const controller = new AbortController();
    const probe = async () => {
      const online = await checkApi(controller.signal);
      setServerOnline(online);
      if (!online) return;
      await flushPendingConsentUpdates();
      const activeProfile = profileRef.current;
      const link = await syncRemoteProfile(activeProfile);
      if (link) {
        setRemoteProfileId(link.profileId);
        setCaregiverProfileId((current) => current ?? link.profileId);
        setCaregiverProfileInput((current) => current || link.profileId);
      } else if (activeProfile.consentToEventSync || activeProfile.consentToCaregiverAlerts) {
        setCaregiverMessage("Cloud data is queued locally. An authenticated gateway session may be required.");
      }
      await flushOutbox(activeProfile);
    };
    void probe();
    const timer = window.setInterval(() => void probe(), 15_000);
    window.addEventListener("online", probe);
    return () => {
      controller.abort();
      window.clearInterval(timer);
      window.removeEventListener("online", probe);
    };
  }, []);

  useEffect(() => {
    if (!serverOnline) return;
    let cancelled = false;
    void (async () => {
      await flushPendingConsentUpdates();
      const link = await syncRemoteProfile(profile);
      if (!cancelled && link) {
        setRemoteProfileId(link.profileId);
        setCaregiverProfileId((current) => current ?? link.profileId);
        setCaregiverProfileInput((current) => current || link.profileId);
      } else if (!cancelled && (profile.consentToEventSync || profile.consentToCaregiverAlerts)) {
        setCaregiverMessage("Cloud data is queued locally. An authenticated gateway session may be required.");
      }
      await flushOutbox(profile);
    })();
    return () => { cancelled = true; };
  }, [profile, serverOnline]);

  useEffect(() => {
    if (view !== "caregiver" || !serverOnline || !caregiverProfileId) return;
    let cancelled = false;
    let socket: WebSocket | null = null;
    let reconnectTimer: number | null = null;
    let reconnectAttempt = 0;
    const mergeAlerts = (incoming: CaregiverAlert[]) => setAlerts((current) =>
      [...incoming, ...current]
        .filter((item, index, all) => all.findIndex((candidate) => candidate.id === item.id) === index)
        .sort((left, right) => right.created_at.localeCompare(left.created_at))
        .slice(0, 100));
    const connect = () => {
      if (cancelled) return;
      setSocketStatus("connecting");
      socket = new WebSocket(caregiverSocketUrl(caregiverProfileId));
      socket.onopen = () => {
        reconnectAttempt = 0;
        setSocketStatus("live");
        setCaregiverMessage("Authorized caregiver connection is live.");
      };
      socket.onmessage = (message) => {
        try {
          const payload = JSON.parse(String(message.data)) as { alert?: CaregiverAlert; alerts?: CaregiverAlert[] };
          const incoming = payload.alerts ?? (payload.alert ? [payload.alert] : []);
          if (incoming.length) mergeAlerts(incoming);
        } catch {
          // Ignore malformed network messages; the durable API remains authoritative.
        }
      };
      socket.onclose = (event) => {
        if (cancelled) return;
        setSocketStatus("offline");
        if ([4401, 4403, 4404].includes(event.code)) {
          setCaregiverMessage(event.code === 4401 ? "Caregiver sign-in is required." : event.code === 4403 ? "Caregiver alerts are not consented for this profile." : "Profile not found or access was revoked.");
          return;
        }
        const delay = Math.min(30_000, 1_500 * (2 ** reconnectAttempt)) + Math.floor(Math.random() * 500);
        reconnectAttempt += 1;
        reconnectTimer = window.setTimeout(connect, delay);
      };
      socket.onerror = () => socket?.close();
    };
    void loadCaregiverAlerts(caregiverProfileId).then(mergeAlerts).catch(() => undefined);
    connect();
    return () => {
      cancelled = true;
      if (reconnectTimer !== null) window.clearTimeout(reconnectTimer);
      socket?.close(1000, "leaving caregiver view");
    };
  }, [caregiverProfileId, serverOnline, view]);

  useEffect(() => {
    if (view !== "caregiver" || !serverOnline || !caregiverProfileId) return;
    let cancelled = false;
    const refresh = async () => {
      try {
        const devices = await loadRemoteDevices(caregiverProfileId);
        if (cancelled) return;
        setRemoteDevices(devices);
        const active = devices.find((device) => device.enabled);
        setRemoteDeviceMessage(active
          ? active.online ? `${active.name} is reporting live.` : `${active.name} is registered but currently offline.`
          : "No wheelchair Pi is registered for this patient profile.");
      } catch {
        if (!cancelled) setRemoteDeviceMessage("Patient-device status could not be verified.");
      }
    };
    void refresh();
    const timer = window.setInterval(() => void refresh(), 15_000);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [caregiverProfileId, serverOnline, view]);

  useEffect(() => {
    if ("serviceWorker" in navigator) {
      void navigator.serviceWorker.register("/sw.js", { updateViaCache: "none" })
        .then((registration) => registration.update())
        .catch(() => undefined);
    }
  }, []);

  useEffect(() => {
    window.addEventListener("pagehide", endRemoteSession);
    return () => window.removeEventListener("pagehide", endRemoteSession);
  }, []);

  const stopCamera = useCallback(() => {
    if (animationRef.current !== null) cancelAnimationFrame(animationRef.current);
    animationRef.current = null;
    streamRef.current?.getTracks().forEach((track) => track.stop());
    streamRef.current = null;
    landmarkerRef.current?.close();
    landmarkerRef.current = null;
    recentFramesRef.current = [];
    captureFramesRef.current = [];
    capturingRef.current = false;
    captureTokenRef.current += 1;
    if (captureTimerRef.current !== null) window.clearTimeout(captureTimerRef.current);
    captureTimerRef.current = null;
    setCaptureTarget(null);
    machineRef.current.reset();
    setIntent(machineRef.current.snapshot());
    setTracking(false);
    setCameraStatus("off");
    setCameraMessage("Camera stopped. No camera frames were saved or uploaded.");
    const canvas = canvasRef.current;
    canvas?.getContext("2d")?.clearRect(0, 0, canvas.width, canvas.height);
  }, []);

  useEffect(() => stopCamera, [stopCamera]);

  const queueEvent = useCallback(async (gesture: Gesture, type: OutboxEvent["type"]) => {
    const event: OutboxEvent = {
      id: eventId(),
      type,
      profileId: profileRef.current.id,
      gestureId: gesture.id,
      phrase: type === "caregiver_alert" ? gesture.phrase : undefined,
      risk: type === "caregiver_alert" ? gesture.risk : undefined,
      occurredAt: new Date().toISOString(),
    };
    const currentProfile = profileRef.current;
    const maySync = type === "caregiver_alert" ? currentProfile.consentToCaregiverAlerts : currentProfile.consentToEventSync;
    if (!maySync) return;
    await deviceStorage.queueEvent(event);
    if (maySync) {
      const delivery = await sendEvent(currentProfile, event);
      if (delivery !== "retry") await deviceStorage.deleteEvent(event.id);
      if (delivery === "sent") setServerOnline(true);
    }
  }, []);

  const speakGesture = useCallback((gesture: Gesture, source: SpokenEntry["source"]) => {
    if (!gesture.phrase) return;
    const entry: SpokenEntry = {
      id: eventId(),
      phrase: gesture.phrase,
      gesture: gesture.name,
      risk: gesture.risk,
      at: new Date().toISOString(),
      source,
    };
    setSpoken((current) => [entry, ...current].slice(0, 12));

    if (!("speechSynthesis" in window)) {
      setVoiceMessage("Speech is unavailable on this device. Use the large caption or a backup AAC method.");
      if (gesture.risk !== "routine") void queueEvent(gesture, "caregiver_alert");
      return;
    }
    window.speechSynthesis.cancel();
    const utterance = new SpeechSynthesisUtterance(gesture.phrase);
    const voices = window.speechSynthesis.getVoices();
    const localVoice = voices.find((voice) => voice.localService);
    if (!localVoice) {
      setVoiceMessage("No verified on-device voice is available. The phrase remains on screen; choose a local system voice or use backup AAC.");
      if (gesture.risk !== "routine") void queueEvent(gesture, "caregiver_alert");
      return;
    }
    utterance.voice = localVoice;
    utterance.rate = 0.92;
    utterance.onend = () => {
      setVoiceMessage(`Spoken: “${gesture.phrase}”`);
      void queueEvent(gesture, "phrase_spoken");
    };
    utterance.onerror = () => setVoiceMessage("Voice output failed. The phrase remains on screen—use the backup call control if help is urgent.");
    window.speechSynthesis.speak(utterance);
    if (gesture.risk !== "routine") void queueEvent(gesture, "caregiver_alert");
  }, [queueEvent]);

  const drawHand = useCallback((landmarks: ReadonlyArray<{ x: number; y: number }>) => {
    const video = videoRef.current;
    const canvas = canvasRef.current;
    if (!video || !canvas || !video.videoWidth || !video.videoHeight) return;
    if (canvas.width !== video.videoWidth || canvas.height !== video.videoHeight) {
      canvas.width = video.videoWidth;
      canvas.height = video.videoHeight;
    }
    const context = canvas.getContext("2d");
    if (!context) return;
    context.clearRect(0, 0, canvas.width, canvas.height);
    context.strokeStyle = "rgba(79, 209, 197, .8)";
    context.lineWidth = 3;
    for (const [start, end] of HAND_CONNECTIONS) {
      context.beginPath();
      context.moveTo(landmarks[start].x * canvas.width, landmarks[start].y * canvas.height);
      context.lineTo(landmarks[end].x * canvas.width, landmarks[end].y * canvas.height);
      context.stroke();
    }
    context.fillStyle = "#f6bd60";
    for (const landmark of landmarks) {
      context.beginPath();
      context.arc(landmark.x * canvas.width, landmark.y * canvas.height, 4, 0, Math.PI * 2);
      context.fill();
    }
  }, []);

  const processFrame = useCallback(() => {
    const video = videoRef.current;
    const landmarker = landmarkerRef.current;
    if (!video || !landmarker || video.readyState < 2) {
      animationRef.current = requestAnimationFrame(() => processFrameRef.current());
      return;
    }
    const now = performance.now();
    const result = landmarker.detectForVideo(video, now);
    const landmarks = result.landmarks[0];
    if (!landmarks) {
      setTracking(false);
      recentFramesRef.current = [];
      captureFramesRef.current = [];
      if (capturingRef.current) {
        capturingRef.current = false;
        captureTokenRef.current += 1;
        if (captureTimerRef.current !== null) window.clearTimeout(captureTimerRef.current);
        captureTimerRef.current = null;
        setCaptureTarget(null);
        setCaptureMessage("Tracking was interrupted, so that capture was discarded. Keep one hand visible and try again.");
      }
      const output = machineRef.current.step({ handPresent: false, gestureId: null, confidence: 0, inDistribution: false }, now, profileRef.current.gestures);
      setIntent(output);
      canvasRef.current?.getContext("2d")?.clearRect(0, 0, canvasRef.current.width, canvasRef.current.height);
      animationRef.current = requestAnimationFrame(() => processFrameRef.current());
      return;
    }
    setTracking(true);
    drawHand(landmarks);
    const raw = flattenLandmarks(landmarks);
    const timed = { t: now, raw };
    recentFramesRef.current.push(timed);
    recentFramesRef.current = recentFramesRef.current.filter((frame) => frame.t >= now - 1_500);
    if (capturingRef.current) captureFramesRef.current.push(timed);

    const activeModel = modelRef.current;
    if (activeModel && now - lastInferenceRef.current >= 120) {
      lastInferenceRef.current = now;
      const sequence = resampleSequence(recentFramesRef.current);
      if (sequence) {
        try {
          const nextPrediction = predictPrototype(activeModel, sequence);
          setPrediction({ gestureId: nextPrediction.gestureId, confidence: nextPrediction.confidence, inDistribution: nextPrediction.inDistribution });
          const output = machineRef.current.step({ handPresent: true, gestureId: nextPrediction.gestureId, confidence: nextPrediction.confidence, inDistribution: nextPrediction.inDistribution }, now, profileRef.current.gestures);
          setIntent(output);
          if (output.trigger) speakGesture(output.trigger, "gesture");
        } catch {
          setPrediction({ gestureId: null, confidence: 0, inDistribution: false });
        }
      }
    }
    animationRef.current = requestAnimationFrame(() => processFrameRef.current());
  }, [drawHand, speakGesture]);

  useEffect(() => {
    processFrameRef.current = processFrame;
  }, [processFrame]);

  const startCamera = useCallback(async () => {
    if (cameraStatus === "loading" || cameraStatus === "ready") return;
    setCameraStatus("loading");
    setCameraMessage("Loading the on-device hand model…");
    try {
      const { FilesetResolver, HandLandmarker } = await import("@mediapipe/tasks-vision");
      const vision = await FilesetResolver.forVisionTasks("/mediapipe/wasm");
      let landmarker: HandLandmarker;
      try {
        landmarker = await HandLandmarker.createFromOptions(vision, {
          baseOptions: { modelAssetPath: "/models/hand_landmarker.task", delegate: "GPU" },
          runningMode: "VIDEO",
          numHands: 1,
        });
      } catch {
        landmarker = await HandLandmarker.createFromOptions(vision, {
          baseOptions: { modelAssetPath: "/models/hand_landmarker.task", delegate: "CPU" },
          runningMode: "VIDEO",
          numHands: 1,
        });
      }
      landmarkerRef.current = landmarker;
      const stream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: "user", width: { ideal: 960 }, height: { ideal: 720 } },
        audio: false,
      });
      streamRef.current = stream;
      if (!videoRef.current) throw new Error("Camera view is unavailable.");
      videoRef.current.srcObject = stream;
      await videoRef.current.play();
      setCameraStatus("ready");
      setCameraMessage("Camera ready. Landmarks and recognition stay on this device.");
      animationRef.current = requestAnimationFrame(() => processFrameRef.current());
    } catch (error) {
      stopCamera();
      setCameraStatus("error");
      setCameraMessage(error instanceof Error ? `Camera unavailable: ${error.message}` : "Camera unavailable.");
    }
  }, [cameraStatus, stopCamera]);

  const saveProfile = useCallback(async (next: FingerSpeakProfile) => {
    await deviceStorage.saveProfile(next);
    profileRef.current = next;
    setProfile(next);
  }, []);

  const goTo = useCallback((next: View) => {
    if (next !== view && cameraStatus === "ready") stopCamera();
    if (next !== "caregiver") setSocketStatus("offline");
    setView(next);
  }, [cameraStatus, stopCamera, view]);

  const startCapture = useCallback((gesture: Gesture) => {
    if (cameraStatus !== "ready" || !tracking || capturingRef.current) {
      setCaptureMessage("Start the camera and keep one hand visible before capturing.");
      return;
    }
    capturingRef.current = true;
    captureFramesRef.current = [];
    const captureToken = captureTokenRef.current + 1;
    captureTokenRef.current = captureToken;
    setCaptureTarget(gesture.id);
    setCaptureMessage(`Hold “${gesture.name}” naturally for one second…`);
    captureTimerRef.current = window.setTimeout(async () => {
      if (captureTokenRef.current !== captureToken) return;
      captureTimerRef.current = null;
      capturingRef.current = false;
      setCaptureTarget(null);
      const sequence = resampleSequence(captureFramesRef.current);
      captureFramesRef.current = [];
      if (!sequence) {
        setCaptureMessage("Capture was too short or tracking was interrupted. Please try again.");
        return;
      }
      const current = profileRef.current;
      const next = {
        ...current,
        updatedAt: new Date().toISOString(),
        gestures: current.gestures.map((item) => item.id === gesture.id
          ? { ...item, samples: [...item.samples, { raw: sequence, session: "local-session", capturedAt: new Date().toISOString() }].slice(-48) }
          : item),
      };
      try {
        await saveProfile(next);
        setModel(null);
        await deviceStorage.deleteModel(current.id);
        setCaptureMessage(`Captured “${gesture.name}”. Repeat from a slightly different position.`);
      } catch {
        setCaptureMessage("Capture could not be saved. Device storage must be available before calibration can change.");
      }
    }, 1_050);
  }, [cameraStatus, saveProfile, tracking]);

  const trainLocalModel = useCallback(async () => {
    try {
      const fingerprint = await profileModelFingerprint(profile);
      const trained = trainPrototypeModel(profile.gestures, fingerprint);
      await deviceStorage.saveProfileAndModel(profile, trained);
      setModel(trained);
      machineRef.current.reset();
      setCaptureMessage("On-device model trained. Switch to Speak and hold a gesture until confirmation completes.");
      stopCamera();
      setView("speak");
    } catch (error) {
      setCaptureMessage(error instanceof Error ? error.message : "Could not train the on-device model.");
    }
  }, [profile, stopCamera]);

  const handleManualPhrase = useCallback((gesture: Gesture) => {
    if (gesture.risk === "emergency" && armedGestureId !== gesture.id) {
      setArmedGestureId(gesture.id);
      setVoiceMessage("Emergency phrase armed. Touch it again within three seconds to confirm.");
      if (armedTimerRef.current) clearTimeout(armedTimerRef.current);
      armedTimerRef.current = setTimeout(() => setArmedGestureId(null), 3_000);
      return;
    }
    setArmedGestureId(null);
    speakGesture(gesture, "touch");
  }, [armedGestureId, speakGesture]);

  const importProfile = useCallback(async (file: File) => {
    if (file.size > 5_000_000) {
      setCaptureMessage("Profile rejected: files must be smaller than 5 MB.");
      return;
    }
    try {
      const imported = parseProfile(JSON.parse(await file.text()));
      await detachRemoteProfile(profileRef.current);
      const next = { ...imported, id: "local-profile" };
      await deviceStorage.deleteModel("local-profile");
      await deviceStorage.saveProfileAndConsentGuard(next);
      profileRef.current = next;
      setProfile(next);
      setModel(null);
      setRemoteProfileId(null);
      setCaregiverProfileId(null);
      setCaregiverProfileInput("");
      setCaptureMessage("Profile imported with cloud consent off. Train locally or import its matching checksummed model bundle.");
    } catch (error) {
      setCaptureMessage(error instanceof Error ? `Profile rejected: ${error.message}` : "Profile rejected.");
    }
  }, []);

  const importModelBundle = useCallback(async (files: FileList) => {
    try {
      const activeProfile = profileRef.current;
      const importedModel = await importPrototypeBundle(Array.from(files), activeProfile);
      await deviceStorage.saveProfileAndModel(activeProfile, importedModel);
      setModel(importedModel);
      machineRef.current.reset();
      setCaptureMessage("Checksummed Python edge model imported and bound to this exact gesture profile.");
    } catch (error) {
      setCaptureMessage(error instanceof Error ? `Model rejected: ${error.message}` : "Model bundle rejected.");
    }
  }, []);

  const exportProfile = useCallback(() => {
    const blob = new Blob([JSON.stringify(profile, null, 2)], { type: "application/json" });
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob);
    link.download = "fingerspeak-profile-v3.json";
    link.click();
    URL.revokeObjectURL(link.href);
    setCaptureMessage("Profile exported. Treat it as sensitive health and movement data.");
  }, [profile]);

  const updateConsent = useCallback(async (field: "consentToEventSync" | "consentToCaregiverAlerts", value: boolean) => {
    const next = { ...profileRef.current, [field]: value, updatedAt: new Date().toISOString() };
    if (!value) {
      // Withdrawal takes effect immediately, even if durable device storage is degraded.
      profileRef.current = next;
      setProfile(next);
    }
    try {
      await deviceStorage.saveProfileAndConsentGuard(next);
      profileRef.current = next;
      setProfile(next);
    } catch {
      setCaregiverMessage(value
        ? "Cloud sharing was not enabled because the consent choice could not be saved on this device."
        : "Cloud sharing is off for this session, but the withdrawal could not be saved. Keep this tab open and restore device storage before reloading.");
    }
  }, []);

  const connectCaregiverProfile = useCallback(() => {
    const candidate = caregiverProfileInput.trim();
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(candidate)) {
      setCaregiverMessage("Enter a valid shared profile UUID.");
      return;
    }
    setAlerts([]);
    setCaregiverProfileId(candidate);
    setCaregiverMessage("Connecting with your authenticated caregiver account…");
  }, [caregiverProfileInput]);

  const handleAlertAction = useCallback(async (alert: CaregiverAlert, action: "acknowledge" | "resolve") => {
    try {
      const updated = await updateCaregiverAlert(alert.id, action);
      setAlerts((current) => current.map((item) => item.id === updated.id ? updated : item));
    } catch {
      setCaregiverMessage("The alert could not be updated. Check your caregiver access and connection.");
    }
  }, []);

  const handleCaregiverGrant = useCallback(async () => {
    if (!remoteProfileId || !caregiverSubject.trim()) {
      setCaregiverMessage("Create the remote profile first and enter the caregiver’s authenticated subject.");
      return;
    }
    try {
      await grantCaregiver(remoteProfileId, caregiverSubject.trim());
      setCaregiverSubject("");
      setCaregiverMessage("Caregiver access granted. Share the profile ID through a trusted channel.");
    } catch {
      setCaregiverMessage("Caregiver access could not be granted. Only the profile owner may grant access.");
    }
  }, [caregiverSubject, remoteProfileId]);

  const playLocalText = useCallback((text: string) => {
    if (!("speechSynthesis" in window)) {
      setVoiceMessage("Voice playback is unavailable. The message remains visible.");
      return;
    }
    const voices = window.speechSynthesis.getVoices();
    const localVoice = voices.find((voice) => voice.localService);
    if (!localVoice) {
      setVoiceMessage("No verified on-device voice is available. The message remains visible.");
      return;
    }
    window.speechSynthesis.cancel();
    const utterance = new SpeechSynthesisUtterance(text);
    utterance.voice = localVoice;
    utterance.rate = 0.92;
    utterance.onend = () => setVoiceMessage("Asha played the message aloud on this phone.");
    utterance.onerror = () => setVoiceMessage("Voice playback failed. The message remains visible.");
    window.speechSynthesis.speak(utterance);
  }, []);

  const callNumber = useCallback((value: string, label: string): string => {
    const number = dialablePhone(value);
    if (!number) return `${label} phone is not configured. Add it under Caregiver → Advanced.`;
    window.location.href = `tel:${number}`;
    return `Opening the phone dialer for ${label.toLowerCase()}.`;
  }, []);

  const callCaregiver = useCallback(
    () => callNumber(localContacts.caregiverPhone, localContacts.caregiverName.trim() || "Caregiver"),
    [callNumber, localContacts.caregiverName, localContacts.caregiverPhone],
  );

  const saveLocalContacts = useCallback(async () => {
    const caregiverPhone = dialablePhone(contactDraft.caregiverPhone);
    const patientPhone = dialablePhone(contactDraft.patientPhone);
    if (contactDraft.caregiverPhone.trim() && !caregiverPhone) {
      setLocalSettingsMessage("Enter a valid caregiver phone number or leave it blank.");
      return;
    }
    if (contactDraft.patientPhone.trim() && !patientPhone) {
      setLocalSettingsMessage("Enter a valid patient phone number or leave it blank.");
      return;
    }
    const next: LocalContactSettings = {
      id: "local-contact-settings",
      caregiverName: contactDraft.caregiverName.trim().slice(0, 80),
      caregiverPhone,
      patientPhone,
      updatedAt: new Date().toISOString(),
    };
    try {
      await deviceStorage.saveLocalContactSettings(next);
      setLocalContacts(next);
      setContactDraft(next);
      setLocalSettingsMessage("Local contact settings saved on this device only.");
    } catch {
      setLocalSettingsMessage("Contact settings could not be saved. Existing saved numbers were not changed.");
    }
  }, [contactDraft]);

  const savePiConnection = useCallback(() => {
    const message = piDevice.configureConnection(piEndpointDraft, piPairingTokenDraft);
    setLocalSettingsMessage(message);
  }, [piDevice, piEndpointDraft, piPairingTokenDraft]);

  const confirmEmergencyHelp = useCallback(async () => {
    const emergency = profileRef.current.gestures.find((gesture) => gesture.risk === "emergency");
    if (!emergency) {
      setVoiceMessage("No emergency phrase is configured. Use the caregiver call control.");
      return "No emergency phrase is configured. Use the caregiver call control or another tested emergency pathway.";
    }
    speakGesture(emergency, "touch");
    const displayConfirmed = await piDevice.sendEmergency(emergency.phrase);
    const displayResult = displayConfirmed
      ? "The Pi confirmed its priority emergency display."
      : "The Pi did not confirm its emergency display.";
    return profileRef.current.consentToCaregiverAlerts
      ? `Your help phrase was spoken locally and queued for approved caregivers. ${displayResult} This is not guaranteed emergency delivery.`
      : `Your help phrase was spoken locally. ${displayResult} Caregiver alert sharing is off, so use the call control or another tested emergency pathway.`;
  }, [piDevice, speakGesture]);

  const sendCaregiverCaption = useCallback(async () => {
    const caption = caregiverOutboundMessage.trim();
    if (!caption) {
      setCaregiverActionMessage("Type a message before sending it to the patient display.");
      return;
    }
    const remotePi = remoteDevices.find((device) => device.enabled);
    if (remotePi) {
      try {
        await sendRemoteDeviceCaption(remotePi.id, caption);
        setCaregiverActionMessage(remotePi.online
          ? "Message queued and sent through the patient’s cloud-connected Pi channel."
          : "Message queued securely; it will expire if the patient’s Pi stays offline.");
        setCaregiverOutboundMessage("");
        return;
      } catch {
        setCaregiverActionMessage("The cloud message could not be queued. Trying the direct local Pi link…");
      }
    }
    const delivered = await piDevice.sendCaption(caption);
    setCaregiverActionMessage(delivered
      ? "The direct paired Pi confirmed the message."
      : "Message previewed locally, but the patient Pi did not confirm it.");
    if (delivered) setCaregiverOutboundMessage("");
  }, [caregiverOutboundMessage, piDevice, remoteDevices]);

  return (
    <div className={view === "pi-display" ? "app-shell pi-display-shell" : "app-shell"}>
      <header className="topbar">
        <button className="brand" onClick={() => goTo("speak")} aria-label="FingerSpeak home">
          <span className="brand-mark">FS</span>
          <span><strong>FingerSpeak</strong><small>Local-first communication</small></span>
        </button>
        <nav className="mode-switch" aria-label="Application views">
          {(["speak", "pi-display", "caregiver", "calibrate"] as View[]).map((item) => {
            const label = item === "speak" ? "Patient" : item === "pi-display" ? "Pi Display" : item === "calibrate" ? "Setup" : "Caregiver";
            const icon = item === "speak" ? "♡" : item === "pi-display" ? "▣" : item === "caregiver" ? "☎" : "⚙";
            return (
              <button key={item} className={view === item ? "active" : ""} onClick={() => goTo(item)} aria-current={view === item ? "page" : undefined}>
                <span className="mode-icon" aria-hidden="true">{icon}</span><span>{label}</span>
              </button>
            );
          })}
        </nav>
        <div className="system-badges">
          <span className="privacy-badge"><i /> Camera on-device</span>
          <span className={piDevice.status === "connected" ? "cloud-badge online" : "cloud-badge"}>{piDevice.status === "connected" ? "Pi paired" : "Pi demo"}</span>
        </div>
      </header>

      <main>
        {view === "speak" && (
          <section className="workspace speak-workspace" aria-labelledby="speak-title">
            <div className="patient-hero section-heading">
              <div className="patient-hero-copy">
                <AshaAvatar variant="hero" eager />
                <div><span className="eyebrow">PATIENT COMPANION</span><h1 id="speak-title">You’re not alone. Asha is right here.</h1><p className="patient-lead">Talk on your phone, write on the wheelchair display, or reach your caregiver—with every important action kept in your control.</p></div>
              </div>
              <span className={tracking ? "tracking-pill live" : "tracking-pill"}>{tracking ? "Hand found" : cameraStatus === "ready" ? "Show one hand" : "Camera idle"}</span>
            </div>
            <div className="camera-column">
              <div className="camera-card">
                <div className="video-stage">
                  <video ref={videoRef} playsInline muted aria-label="Private camera preview" />
                  <canvas ref={canvasRef} aria-hidden="true" />
                  {cameraStatus !== "ready" && (
                    <div className="camera-placeholder">
                      <span className="hand-orbit">✋</span>
                      <strong>{cameraStatus === "loading" ? "Preparing recognition…" : "Camera stays private"}</strong>
                      <p>Only hand landmarks are processed. Video frames never leave this device.</p>
                    </div>
                  )}
                  <div className="camera-status"><span className={tracking ? "status-dot live" : "status-dot"} />{cameraMessage}</div>
                </div>
                <div className="camera-actions">
                  {cameraStatus === "ready" ? (
                    <button className="button secondary" onClick={stopCamera}>Stop camera</button>
                  ) : (
                    <button className="button primary" onClick={() => void startCamera()} disabled={cameraStatus === "loading"}>Start private camera</button>
                  )}
                  <button className="button ghost" onClick={() => goTo("calibrate")}>{model ? "Recalibrate" : "Set up gestures"}</button>
                </div>
              </div>
              <div className="privacy-note"><span>◉</span><p><strong>Speech never waits for the network.</strong> Recognition and safety confirmation happen here first; only confirmed event metadata can sync.</p></div>
            </div>

            <div className="voice-column">
              <AshaCompanion
                aiAvailable={serverOnline}
                patientContext={patientContext}
                caregiverConfigured={Boolean(dialablePhone(localContacts.caregiverPhone))}
                onSpeak={playLocalText}
                onWriteDisplay={piDevice.sendCaption}
                onCallCaregiver={callCaregiver}
                onConfirmEmergency={confirmEmergencyHelp}
              />
            </div>

            <div className="patient-tools">
              <div className="patient-device-strip" aria-label="Current device status">
                <span><strong>Phone</strong> Voice, typing &amp; calls ready</span>
                <span><strong>Pi display</strong>{piDevice.status === "connected" ? " Paired live" : " Demo preview"}</span>
                <span><strong>Pi power</strong> {formatPercent(piDevice.telemetry.piPowerPercent)}</span>
                <span><strong>Wheelchair battery</strong> {formatPercent(piDevice.telemetry.wheelchairBatteryPercent)}</span>
              </div>
              <div className="intent-card">
                <div className="intent-topline"><span>LIVE INTENT</span><span className={`intent-state state-${intent.state.toLowerCase()}`}>{intent.state === "WAIT_RELEASE" ? "Release hand" : intent.state}</span></div>
                <div className="recognized-gesture">
                  <div className={`gesture-orb ${currentGesture?.risk === "emergency" ? "danger" : ""}`} style={{ "--progress": `${Math.round(intent.progress * 360)}deg` } as React.CSSProperties}>
                    <span>{prediction.inDistribution ? currentGesture?.icon ?? "·" : "·"}</span>
                  </div>
                  <div><small>{model ? "Recognizing locally" : "Calibration needed"}</small><strong>{model ? (prediction.inDistribution ? currentGesture?.name ?? "Watching…" : "Unrecognized movement") : "Touch phrases still work"}</strong><p>{Math.round(prediction.confidence * 100)}% match · {intent.state === "CANDIDATE" ? "keep holding" : intent.state === "WAIT_RELEASE" ? "return to Rest" : "ready"}</p></div>
                </div>
                <div className="confidence-track" aria-label={`Confirmation ${Math.round(intent.progress * 100)} percent`}><span style={{ width: `${intent.progress * 100}%` }} /></div>
              </div>

              <div className="phrase-header"><div><span className="eyebrow">TOUCH BACKUP</span><h2>Say it now</h2></div><span className="voice-status" role="status">{voiceMessage}</span></div>
              <div className="phrase-grid">
                {profile.gestures.filter((gesture) => gesture.phrase).map((gesture) => (
                  <button key={gesture.id} className={`phrase-button risk-${gesture.risk} ${armedGestureId === gesture.id ? "armed" : ""}`} onClick={() => handleManualPhrase(gesture)}>
                    <span className="phrase-icon" aria-hidden="true">{gesture.icon}</span>
                    <span><strong>{armedGestureId === gesture.id ? "Touch again to confirm" : gesture.name}</strong><small>{gesture.phrase}</small></span>
                    <span className="speak-arrow" aria-hidden="true">›</span>
                  </button>
                ))}
              </div>
            </div>
          </section>
        )}

        {view === "pi-display" && (
          <PiDisplayView status={piDevice.status} statusMessage={piDevice.message} telemetry={piDevice.telemetry} />
        )}

        {view === "calibrate" && (
          <section className="calibration-page" aria-labelledby="calibrate-title">
            <div className="page-intro">
              <span className="eyebrow">PERSONALIZED CALIBRATION</span>
              <h1 id="calibrate-title">Teach FingerSpeak the movement you can make.</h1>
              <p>Two examples unlock the local baseline. More examples across different sessions improve reliability. Rest is always protected.</p>
            </div>
            <div className="calibration-layout">
              <div className="calibration-main">
                <div className="calibration-progress">
                  <div><span>{Math.min(capturedCount, requiredCount)} / {requiredCount}</span><small>minimum captures</small></div>
                  <div className="progress-track"><span style={{ width: `${Math.min(100, capturedCount / requiredCount * 100)}%` }} /></div>
                  <strong>{calibrationReady ? "Ready to train" : "Keep going"}</strong>
                </div>
                <div className="gesture-list">
                  {profile.gestures.map((gesture, index) => (
                    <article className="gesture-row" key={gesture.id}>
                      <span className="gesture-number">{String(index + 1).padStart(2, "0")}</span>
                      <span className={`mini-icon risk-${gesture.risk}`}>{gesture.icon}</span>
                      <div className="gesture-copy"><strong>{gesture.name}</strong><small>{gesture.phrase || "Neutral / release state"}</small></div>
                      <div className="sample-dots" aria-label={`${gesture.samples.length} samples`}>
                        {[0, 1, 2, 3, 4].map((dot) => <i key={dot} className={dot < gesture.samples.length ? "filled" : ""} />)}
                      </div>
                      <button className="button capture" onClick={() => startCapture(gesture)} disabled={captureTarget !== null}>
                        {captureTarget === gesture.id ? "Capturing…" : "Capture"}
                      </button>
                    </article>
                  ))}
                </div>
              </div>
              <aside className="calibration-aside">
                <div className="mini-camera">
                  <video ref={view === "calibrate" ? videoRef : undefined} playsInline muted aria-label="Calibration camera preview" />
                  <canvas ref={view === "calibrate" ? canvasRef : undefined} aria-hidden="true" />
                  {cameraStatus !== "ready" && <div><span>✋</span><p>Start the camera to capture movements.</p></div>}
                </div>
                {cameraStatus === "ready" ? <button className="button secondary full" onClick={stopCamera}>Stop camera</button> : <button className="button primary full" onClick={() => void startCamera()} disabled={cameraStatus === "loading"}>Start private camera</button>}
                <p className="capture-message" role="status">{captureMessage}</p>
                <button className="button train full" onClick={() => void trainLocalModel()} disabled={!calibrationReady}>Train on this device</button>
                <div className="profile-tools">
                  <button onClick={exportProfile}>Export profile JSON*</button>
                  <button onClick={() => fileInputRef.current?.click()}>Import profile</button>
                  <input ref={fileInputRef} type="file" accept="application/json" hidden onChange={(event) => { const file = event.target.files?.[0]; if (file) void importProfile(file); event.currentTarget.value = ""; }} />
                  <button onClick={() => modelInputRef.current?.click()}>Import Python model</button>
                  <input ref={modelInputRef} type="file" accept="application/json" multiple hidden onChange={(event) => { if (event.target.files?.length) void importModelBundle(event.target.files); event.currentTarget.value = ""; }} />
                </div>
                <small className="asterisk">*Profile JSON is not encrypted. For a Python model, select manifest.json and edge-prototype.json together.</small>
              </aside>
            </div>
          </section>
        )}

        {view === "caregiver" && (
          <section className="caregiver-page" aria-labelledby="caregiver-title">
            <div className="page-intro caregiver-intro">
              <div><span className="eyebrow">CAREGIVER VIEW</span><h1 id="caregiver-title">The essentials, at a glance.</h1><p>See confirmed communication and honest device status, then call or write to the patient without navigating a clinical dashboard.</p></div>
              <span className={socketStatus === "live" ? "connection-card online" : "connection-card"}><i />{socketStatus === "live" ? "Patient channel live" : socketStatus === "connecting" ? "Connecting…" : "Patient channel offline"}</span>
            </div>

            <section className="caregiver-status-grid" aria-label="Patient and wheelchair status">
              <article className={caregiverDeviceOnline ? "live" : ""}><small>PATIENT DEVICE</small><strong>{caregiverDeviceOnline ? "Online" : "Not verified"}</strong><span>{remoteDeviceMessage}</span></article>
              <article className={caregiverDeviceOnline ? "live" : ""}><small>PI DISPLAY</small><strong>{caregiverDeviceState ? caregiverDeviceState.display_status : piDevice.status === "connected" ? "Paired live" : "Unavailable"}</strong><span>{caregiverRemotePi ? `Cloud relay · ${caregiverDeviceState?.transport ?? "unknown transport"}` : piDevice.message}</span></article>
              <article><small>PI POWER</small><strong>{formatPercent(caregiverDeviceState?.pi_battery_percent ?? piDevice.telemetry.piPowerPercent)}</strong><span>Reported separately by Pi/UPS telemetry</span></article>
              <article><small>WHEELCHAIR BATTERY</small><strong>{formatPercent(caregiverDeviceState?.wheelchair_battery_percent ?? piDevice.telemetry.wheelchairBatteryPercent)}</strong><span>{caregiverDeviceState ? `Chair: ${caregiverDeviceState.wheelchair_status}` : "Unknown until chair/BMS telemetry exists"}</span></article>
            </section>

            <div className="caregiver-grid caregiver-primary-grid">
              <section className="alerts-card">
                <div className="card-title"><div><span className="eyebrow">LATEST CONFIRMED ACTIVITY</span><h2>Patient timeline</h2></div><span>{spoken.length + alerts.length} events</span></div>
                <div className="timeline">
                  {alerts.map((alert) => (
                    <article key={alert.id} className={`timeline-event ${alert.severity}`}>
                      <i />
                      <div><strong>{alert.message}</strong><p>Confirmed on patient device · {alert.status}</p><span className="alert-actions">{alert.status === "pending" && <button onClick={() => void handleAlertAction(alert, "acknowledge")}>Acknowledge</button>}{alert.status !== "resolved" && <button onClick={() => void handleAlertAction(alert, "resolve")}>Resolve</button>}</span></div>
                      <time>{new Date(alert.created_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</time>
                    </article>
                  ))}
                  {spoken.map((entry) => (
                    <article key={entry.id} className={`timeline-event ${entry.risk}`}><i /><div><strong>{entry.phrase}</strong><p>{entry.gesture} · {entry.source === "gesture" ? "gesture confirmed" : "touch backup"}</p></div><time>{new Date(entry.at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</time></article>
                  ))}
                  {!spoken.length && !alerts.length && <div className="empty-state"><span>○</span><strong>No confirmed events yet</strong><p>Patient-selected phrases and consented alerts will appear here.</p></div>}
                </div>
              </section>
              <aside className="caregiver-side caregiver-actions-card">
                <section className="contact-patient-card">
                  <span className="eyebrow">CONTACT PATIENT</span><h2>Call or write</h2>
                  <button className="caregiver-call-button" type="button" onClick={() => setCaregiverActionMessage(callNumber(localContacts.patientPhone, "Patient"))}>☎ Call patient</button>
                  <label htmlFor="caregiver-caption">Message on Pi display</label>
                  <textarea id="caregiver-caption" value={caregiverOutboundMessage} onChange={(event) => setCaregiverOutboundMessage(event.target.value)} rows={4} maxLength={500} placeholder="I’m on my way. You’re not alone." />
                  <button className="caregiver-message-button" type="button" onClick={() => void sendCaregiverCaption()}>Write on patient display</button>
                  <small role="status">{caregiverActionMessage}</small>
                </section>
                <section className="safety-card"><strong>Not an emergency service</strong><p>Calls, direct Pi messages, and caregiver WebSockets are convenience pathways. Keep a tested emergency route available.</p></section>
              </aside>
            </div>

            <details className="caregiver-advanced">
              <summary><span><strong>Advanced settings &amp; privacy</strong><small>Local contacts, Pi pairing, authorized access, consent, and calibration quality</small></span><b>Open</b></summary>
              <div className="advanced-grid">
                <section className="access-card local-settings-card">
                  <span className="eyebrow">LOCAL PHONE SETTINGS</span><h2>Contacts on this device</h2>
                  <label>Caregiver name<input value={contactDraft.caregiverName} onChange={(event) => setContactDraft((current) => ({ ...current, caregiverName: event.target.value }))} maxLength={80} placeholder="Family or caregiver" /></label>
                  <label>Caregiver phone<input value={contactDraft.caregiverPhone} onChange={(event) => setContactDraft((current) => ({ ...current, caregiverPhone: event.target.value }))} inputMode="tel" autoComplete="tel" placeholder="Add locally" /></label>
                  <label>Patient phone<input value={contactDraft.patientPhone} onChange={(event) => setContactDraft((current) => ({ ...current, patientPhone: event.target.value }))} inputMode="tel" autoComplete="tel" placeholder="Add locally" /></label>
                  <button type="button" onClick={() => void saveLocalContacts()}>Save local contacts</button>
                  <small>These numbers are stored in this browser’s device database and are never added to profile or telemetry requests.</small>
                </section>

                <section className="access-card local-settings-card">
                  <span className="eyebrow">DIRECT PI PAIRING</span><h2>Wheelchair connection</h2>
                  <label>Pi WebSocket address<input value={piEndpointDraft} onChange={(event) => setPiEndpointDraft(event.target.value)} inputMode="url" placeholder="ws://fingerspeak-pi.local:8765/v1/device/ws" /></label>
                  <label>Local pairing token<input type="password" value={piPairingTokenDraft} onChange={(event) => setPiPairingTokenDraft(event.target.value)} autoComplete="off" placeholder="Stored separately from the URL" /></label>
                  <button type="button" onClick={savePiConnection}>Save &amp; pair</button>
                  <small>On connection, the browser sends one protocol-bounded <code>pairing.authenticate</code> message. Telemetry is ignored until the Pi replies <code>pairing.authenticated</code>; the one-time code is then rotated locally.</small>
                  <small>Direct <code>ws://</code> pairing is for the local prototype. The deployed HTTPS app uses a configured <code>wss://</code> origin or the Pi’s outbound cloud relay.</small>
                  <small role="status">{localSettingsMessage}</small>
                </section>

                <section className="access-card"><span className="eyebrow">AUTHORIZED ACCESS</span><h2>Connect a caregiver</h2><label>Shared profile ID<input value={caregiverProfileInput} onChange={(event) => setCaregiverProfileInput(event.target.value)} placeholder="00000000-0000-0000-0000-000000000000" /></label><button type="button" onClick={connectCaregiverProfile}>Open authorized dashboard</button><label>Caregiver subject (owner only)<input value={caregiverSubject} onChange={(event) => setCaregiverSubject(event.target.value)} placeholder="caregiver account subject" /></label><button type="button" onClick={() => void handleCaregiverGrant()}>Grant caregiver access</button><small role="status">{caregiverMessage}</small>{remoteProfileId && <code>Profile: {remoteProfileId}</code>}</section>
                <section className="metrics-card"><span className="eyebrow">SESSION QUALITY</span><div className="metric-grid"><div><strong>{spoken.length}</strong><small>phrases</small></div><div><strong>{falseActivations}</strong><small>false activations</small></div><div><strong>{missedGestures}</strong><small>missed gestures</small></div><div><strong>{model ? "Ready" : "Setup"}</strong><small>edge model</small></div></div><div className="metric-actions"><button type="button" onClick={() => { setFalseActivations((value) => value + 1); const rest = profile.gestures.find((gesture) => gesture.id === "rest"); if (rest) void queueEvent(rest, "false_activation"); }}>Mark false activation</button><button type="button" onClick={() => { setMissedGestures((value) => value + 1); const rest = profile.gestures.find((gesture) => gesture.id === "rest"); if (rest) void queueEvent(rest, "missed_gesture"); }}>Mark missed gesture</button></div></section>
                <section className="consent-card"><div><span className="eyebrow">DATA CONTROL</span><h2>Cloud sharing</h2></div><div className="toggle-row"><span><strong>Share confirmed activity</strong><small>Opaque gesture keys and timing only</small></span><button className="switch" type="button" role="switch" aria-label="Share confirmed activity events" aria-checked={profile.consentToEventSync} onClick={() => void updateConsent("consentToEventSync", !profile.consentToEventSync)}><i /></button></div><div className="toggle-row"><span><strong>Send caregiver alerts</strong><small>Confirmed request text is shared with approved caregivers</small></span><button className="switch" type="button" role="switch" aria-label="Send confirmed caregiver alerts" aria-checked={profile.consentToCaregiverAlerts} onClick={() => void updateConsent("consentToCaregiverAlerts", !profile.consentToCaregiverAlerts)}><i /></button></div><p>Video, audio, hand landmarks, raw calibration sequences, labels, and routine phrases always remain on this device.</p></section>
              </div>
            </details>
          </section>
        )}
      </main>

      <footer><span>FingerSpeak prototype · not a validated medical device</span><span>Local inference → immediate speech → optional secure sync</span></footer>
    </div>
  );
}
