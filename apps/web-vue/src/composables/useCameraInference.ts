import type { FaceLandmarker, HandLandmarker } from "@mediapipe/tasks-vision";
import { computed, onBeforeUnmount, ref, shallowRef } from "vue";
import {
  CONFIDENCE_THRESHOLD,
  flattenLandmarks,
  predictPrototype,
  profileModelFingerprint,
  resampleSequence,
  trainPrototypeModel,
  type Gesture,
  type TimedRawFrame,
} from "../lib/fingerspeak";
import { IntentMachine, type IntentOutput } from "../lib/intent-machine";
import { useFingerSpeakStore } from "../stores/fingerspeak";
import { useCopilotStore, type WellbeingCue } from "../stores/copilot";
import { useCommunication } from "./useCommunication";

export type CameraStatus = "off" | "loading" | "ready" | "error";
export type HeadDirection = "center" | "left" | "right" | "up" | "down";
export type EyeActivity = "steady" | "blink" | "looking-left" | "looking-right" | "looking-up" | "looking-down" | "rapid";
export type VisionSignals = {
  handCount: number;
  facePresent: boolean;
  head: HeadDirection;
  eyes: EyeActivity;
  smile: number;
  sadness: number;
  discomfort: number;
  distress: number;
  cue: WellbeingCue;
  faceModelReady: boolean;
  note: string;
};
export type HandPrediction = { handedness: string; gestureId: string | null; confidence: number; inDistribution: boolean };

const HAND_CONNECTIONS = [
  [0, 1], [1, 2], [2, 3], [3, 4], [0, 5], [5, 6], [6, 7], [7, 8], [5, 9], [9, 10],
  [10, 11], [11, 12], [9, 13], [13, 14], [14, 15], [15, 16], [13, 17], [17, 18], [18, 19], [19, 20], [0, 17],
] as const;
const FACE_MODEL_URL = import.meta.env.VITE_FACE_LANDMARKER_URL
  || "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task";

function clamp(value: number): number { return Math.max(0, Math.min(1, value)); }
function avg(...values: number[]): number { return values.reduce((sum, value) => sum + value, 0) / Math.max(1, values.length); }

export function useCameraInference() {
  const store = useFingerSpeakStore();
  const copilot = useCopilotStore();
  const communication = useCommunication();
  const videoEl = ref<HTMLVideoElement | null>(null);
  const canvasEl = ref<HTMLCanvasElement | null>(null);
  const cameraStatus = ref<CameraStatus>("off");
  const cameraMessage = ref("Camera is off. Touch controls remain available.");
  const tracking = ref(false);
  const faceTracking = ref(false);
  const handCount = ref(0);
  const inferenceMs = ref(0);
  const captureTarget = ref<string | null>(null);
  const captureMessage = ref("Capture two clear examples of each movement with either comfortable hand.");
  const prediction = ref({ gestureId: null as string | null, confidence: 0, inDistribution: false });
  const handPredictions = ref<HandPrediction[]>([]);
  const visionSignals = ref<VisionSignals>({
    handCount: 0, facePresent: false, head: "center", eyes: "steady", smile: 0, sadness: 0,
    discomfort: 0, distress: 0, cue: "neutral", faceModelReady: false,
    note: "Face wellbeing cues load separately and never make a diagnosis.",
  });
  const machine = new IntentMachine(CONFIDENCE_THRESHOLD, 5);
  const intent = ref<IntentOutput>(machine.snapshot());
  const stream = shallowRef<MediaStream | null>(null);
  const handLandmarker = shallowRef<HandLandmarker | null>(null);
  const faceLandmarker = shallowRef<FaceLandmarker | null>(null);
  const recentByHand = new Map<string, TimedRawFrame[]>();
  const captureFrames: TimedRawFrame[] = [];
  const eyeMotion: Array<{ t: number; x: number; y: number }> = [];
  let animationFrame: number | null = null;
  let captureTimer: number | null = null;
  let captureToken = 0;
  let capturing = false;
  let lastInference = 0;
  let lastFaceInference = 0;
  let wellbeingCandidate: WellbeingCue = "neutral";
  let wellbeingCandidateSince = 0;

  const currentGesture = computed(() => store.profile.gestures.find((gesture) => gesture.id === prediction.value.gestureId) ?? null);

  function setupCanvas(): CanvasRenderingContext2D | null {
    const video = videoEl.value;
    const canvas = canvasEl.value;
    if (!video || !canvas || !video.videoWidth || !video.videoHeight) return null;
    if (canvas.width !== video.videoWidth || canvas.height !== video.videoHeight) { canvas.width = video.videoWidth; canvas.height = video.videoHeight; }
    const context = canvas.getContext("2d");
    context?.clearRect(0, 0, canvas.width, canvas.height);
    return context;
  }

  function drawHands(context: CanvasRenderingContext2D, hands: ReadonlyArray<ReadonlyArray<{ x: number; y: number }>>): void {
    const canvas = canvasEl.value!;
    hands.forEach((landmarks, handIndex) => {
      context.strokeStyle = handIndex === 0 ? "rgba(118, 246, 216, .95)" : "rgba(245, 174, 255, .95)";
      context.fillStyle = handIndex === 0 ? "#f4ca78" : "#a9e6ff";
      context.lineWidth = 3;
      context.shadowBlur = 12;
      context.shadowColor = context.strokeStyle;
      for (const [start, end] of HAND_CONNECTIONS) {
        context.beginPath();
        context.moveTo(landmarks[start].x * canvas.width, landmarks[start].y * canvas.height);
        context.lineTo(landmarks[end].x * canvas.width, landmarks[end].y * canvas.height);
        context.stroke();
      }
      for (const landmark of landmarks) {
        context.beginPath(); context.arc(landmark.x * canvas.width, landmark.y * canvas.height, 3.5, 0, Math.PI * 2); context.fill();
      }
      context.shadowBlur = 0;
    });
  }

  function drawFace(context: CanvasRenderingContext2D, landmarks: ReadonlyArray<{ x: number; y: number }>): void {
    const canvas = canvasEl.value!;
    const points = [1, 33, 263, 61, 291, 13, 14, 159, 145, 386, 374, 468, 473];
    context.fillStyle = "rgba(255,255,255,.82)";
    context.shadowBlur = 10;
    context.shadowColor = "rgba(180, 133, 255, .9)";
    for (const index of points) {
      const point = landmarks[index]; if (!point) continue;
      context.beginPath(); context.arc(point.x * canvas.width, point.y * canvas.height, 2.5, 0, Math.PI * 2); context.fill();
    }
    context.shadowBlur = 0;
  }

  function discardInterruptedCapture(): void {
    if (!capturing) return;
    capturing = false; captureToken += 1;
    if (captureTimer !== null) window.clearTimeout(captureTimer);
    captureTimer = null; captureTarget.value = null; captureFrames.splice(0);
    captureMessage.value = "Tracking was interrupted, so the capture was discarded. Keep at least one hand visible and try again.";
  }

  function scoreMap(categories: ReadonlyArray<{ categoryName?: string; score?: number }> | undefined): Map<string, number> {
    return new Map((categories ?? []).map((item) => [item.categoryName ?? "", item.score ?? 0]));
  }

  function blend(scores: Map<string, number>, name: string): number { return scores.get(name) ?? 0; }

  function updateFaceSignals(result: ReturnType<FaceLandmarker["detectForVideo"]>, now: number): void {
    const face = result.faceLandmarks?.[0];
    if (!face) {
      faceTracking.value = false;
      visionSignals.value = { ...visionSignals.value, facePresent: false, head: "center", eyes: "steady", cue: "neutral", note: "Face not in view. Hand communication remains available." };
      return;
    }
    faceTracking.value = true;
    const scores = scoreMap(result.faceBlendshapes?.[0]?.categories);
    const smile = clamp(avg(blend(scores, "mouthSmileLeft"), blend(scores, "mouthSmileRight")));
    const sadness = clamp(avg(blend(scores, "mouthFrownLeft"), blend(scores, "mouthFrownRight"), blend(scores, "browInnerUp")) * 1.18);
    const discomfort = clamp(avg(
      blend(scores, "browDownLeft"), blend(scores, "browDownRight"), blend(scores, "eyeSquintLeft"),
      blend(scores, "eyeSquintRight"), blend(scores, "noseSneerLeft"), blend(scores, "noseSneerRight"),
    ) * 1.32);
    const blink = avg(blend(scores, "eyeBlinkLeft"), blend(scores, "eyeBlinkRight"));
    const jawOpen = blend(scores, "jawOpen");
    const distress = clamp((sadness * .5) + (discomfort * .28) + (Math.max(blink, jawOpen) * .22));

    const nose = face[1], leftEye = face[33], rightEye = face[263], forehead = face[10], chin = face[152];
    let head: HeadDirection = "center";
    if (nose && leftEye && rightEye) {
      const midpointX = (leftEye.x + rightEye.x) / 2;
      const eyeWidth = Math.abs(rightEye.x - leftEye.x) || .001;
      const yaw = (nose.x - midpointX) / eyeWidth;
      if (yaw > .12) head = "left"; else if (yaw < -.12) head = "right";
    }
    if (head === "center" && nose && forehead && chin) {
      const verticalMid = (forehead.y + chin.y) / 2;
      const faceHeight = Math.abs(chin.y - forehead.y) || .001;
      const pitch = (nose.y - verticalMid) / faceHeight;
      if (pitch > .08) head = "down"; else if (pitch < -.08) head = "up";
    }

    const lookLeft = avg(blend(scores, "eyeLookOutLeft"), blend(scores, "eyeLookInRight"));
    const lookRight = avg(blend(scores, "eyeLookInLeft"), blend(scores, "eyeLookOutRight"));
    const lookUp = avg(blend(scores, "eyeLookUpLeft"), blend(scores, "eyeLookUpRight"));
    const lookDown = avg(blend(scores, "eyeLookDownLeft"), blend(scores, "eyeLookDownRight"));
    const gazeX = lookRight - lookLeft;
    const gazeY = lookDown - lookUp;
    eyeMotion.push({ t: now, x: gazeX, y: gazeY });
    while (eyeMotion.length && eyeMotion[0].t < now - 900) eyeMotion.shift();
    let motion = 0;
    for (let i = 1; i < eyeMotion.length; i += 1) motion += Math.hypot(eyeMotion[i].x - eyeMotion[i - 1].x, eyeMotion[i].y - eyeMotion[i - 1].y);
    let eyes: EyeActivity = "steady";
    if (blink > .62) eyes = "blink";
    else if (motion > 2.3 && eyeMotion.length >= 5) eyes = "rapid";
    else if (Math.abs(gazeX) > .28) eyes = gazeX > 0 ? "looking-right" : "looking-left";
    else if (Math.abs(gazeY) > .28) eyes = gazeY > 0 ? "looking-down" : "looking-up";

    let cue: WellbeingCue = "neutral";
    if (distress > .62 && sadness > .42) cue = "crying";
    else if (discomfort > .56) cue = "pain";
    else if (sadness > .52) cue = "sad";
    else if (smile > .52) cue = "smile";

    if (cue !== wellbeingCandidate) { wellbeingCandidate = cue; wellbeingCandidateSince = now; }
    if (now - wellbeingCandidateSince > 1_100 && copilot.wellbeingCue !== wellbeingCandidate) copilot.wellbeingCue = wellbeingCandidate;

    visionSignals.value = {
      handCount: handCount.value, facePresent: true, head, eyes, smile, sadness, discomfort, distress, cue,
      faceModelReady: true,
      note: cue === "pain" ? "Possible discomfort expression — ask, don’t assume."
        : cue === "crying" ? "Possible distress/cry-like expression — camera cannot verify tears."
        : eyes === "rapid" ? "Rapid gaze change observed — confirm context before acting."
        : "Wellbeing cues are observations only, not medical diagnoses.",
    };
  }

  function processFrame(): void {
    const video = videoEl.value;
    const handsDetector = handLandmarker.value;
    if (!video || !handsDetector || video.readyState < 2) { animationFrame = requestAnimationFrame(processFrame); return; }
    const now = performance.now();
    const start = performance.now();
    const handResult = handsDetector.detectForVideo(video, now);
    const hands = handResult.landmarks ?? [];
    handCount.value = hands.length;
    tracking.value = hands.length > 0;
    visionSignals.value.handCount = hands.length;
    const context = setupCanvas();
    if (context && hands.length) drawHands(context, hands);

    const activeKeys = new Set<string>();
    hands.forEach((landmarks, index) => {
      const label = handResult.handedness?.[index]?.[0]?.categoryName ?? `Hand ${index + 1}`;
      const key = label;
      activeKeys.add(key);
      const frames = recentByHand.get(key) ?? [];
      frames.push({ t: now, raw: flattenLandmarks(landmarks) });
      while (frames.length && frames[0].t < now - 1_500) frames.shift();
      recentByHand.set(key, frames);
      if (capturing && index === 0) captureFrames.push({ t: now, raw: flattenLandmarks(landmarks) });
    });
    for (const key of recentByHand.keys()) if (!activeKeys.has(key)) recentByHand.delete(key);
    if (!hands.length) discardInterruptedCapture();

    if (store.model && now - lastInference >= 120) {
      lastInference = now;
      const nextHands: HandPrediction[] = [];
      for (const [key, frames] of recentByHand) {
        const sequence = resampleSequence(frames);
        if (!sequence) continue;
        try {
          const next = predictPrototype(store.model, sequence);
          nextHands.push({ handedness: key, gestureId: next.gestureId, confidence: next.confidence, inDistribution: next.inDistribution });
        } catch { /* ignore one-hand inference failures */ }
      }
      handPredictions.value = nextHands;
      const best = [...nextHands].filter((item) => item.inDistribution).sort((a, b) => b.confidence - a.confidence)[0]
        ?? [...nextHands].sort((a, b) => b.confidence - a.confidence)[0];
      prediction.value = best ? { gestureId: best.gestureId, confidence: best.confidence, inDistribution: best.inDistribution }
        : { gestureId: null, confidence: 0, inDistribution: false };
      const output = machine.step({
        handPresent: hands.length > 0,
        gestureId: prediction.value.gestureId,
        confidence: prediction.value.confidence,
        inDistribution: prediction.value.inDistribution,
      }, now, store.profile.gestures);
      intent.value = output;
      if (output.trigger) communication.speakGesture(output.trigger, "gesture");
    } else if (!hands.length) {
      prediction.value = { gestureId: null, confidence: 0, inDistribution: false };
      handPredictions.value = [];
      intent.value = machine.step({ handPresent: false, gestureId: null, confidence: 0, inDistribution: false }, now, store.profile.gestures);
    }

    if (faceLandmarker.value && now - lastFaceInference >= 100) {
      lastFaceInference = now;
      try {
        const faceResult = faceLandmarker.value.detectForVideo(video, now);
        updateFaceSignals(faceResult, now);
        if (context && faceResult.faceLandmarks?.[0]) drawFace(context, faceResult.faceLandmarks[0]);
      } catch { faceTracking.value = false; }
    }
    inferenceMs.value = performance.now() - start;
    animationFrame = requestAnimationFrame(processFrame);
  }

  async function startCamera(): Promise<void> {
    if (cameraStatus.value === "loading" || cameraStatus.value === "ready") return;
    cameraStatus.value = "loading";
    cameraMessage.value = "Loading private two-hand vision…";
    try {
      const { FilesetResolver, HandLandmarker, FaceLandmarker } = await import("@mediapipe/tasks-vision");
      const vision = await FilesetResolver.forVisionTasks("/mediapipe/wasm");
      const createHands = (delegate: "GPU" | "CPU") => HandLandmarker.createFromOptions(vision, {
        baseOptions: { modelAssetPath: "/models/hand_landmarker.task", delegate }, runningMode: "VIDEO", numHands: 2,
        minHandDetectionConfidence: .45, minHandPresenceConfidence: .45, minTrackingConfidence: .45,
      });
      try { handLandmarker.value = await createHands("GPU"); } catch { handLandmarker.value = await createHands("CPU"); }

      stream.value = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "user", width: { ideal: 960 }, height: { ideal: 720 } }, audio: false });
      if (!videoEl.value) throw new Error("Camera view is unavailable.");
      videoEl.value.srcObject = stream.value;
      await videoEl.value.play();
      cameraStatus.value = "ready";
      cameraMessage.value = "Two-hand gesture tracking ready. Loading optional face/head/eye cues…";
      animationFrame = requestAnimationFrame(processFrame);

      try {
        faceLandmarker.value = await FaceLandmarker.createFromOptions(vision, {
          baseOptions: { modelAssetPath: FACE_MODEL_URL, delegate: "GPU" }, runningMode: "VIDEO", numFaces: 1,
          outputFaceBlendshapes: true, outputFacialTransformationMatrixes: false,
          minFaceDetectionConfidence: .45, minFacePresenceConfidence: .45, minTrackingConfidence: .45,
        });
      } catch {
        try {
          faceLandmarker.value = await FaceLandmarker.createFromOptions(vision, {
            baseOptions: { modelAssetPath: FACE_MODEL_URL, delegate: "CPU" }, runningMode: "VIDEO", numFaces: 1,
            outputFaceBlendshapes: true, outputFacialTransformationMatrixes: false,
          });
        } catch {
          faceLandmarker.value = null;
          visionSignals.value = { ...visionSignals.value, faceModelReady: false, note: "Face cue model could not load. Two-hand communication still works offline." };
        }
      }
      if (cameraStatus.value === "ready") {
        cameraMessage.value = faceLandmarker.value
          ? "Camera ready: two hands + face/head/eye wellbeing cues. Processing stays in this browser."
          : "Camera ready: two-hand gesture tracking active. Face cues need their model connection.";
      }
    } catch (error) {
      stopCamera(); cameraStatus.value = "error";
      cameraMessage.value = error instanceof Error ? `Camera unavailable: ${error.message}` : "Camera unavailable.";
    }
  }

  function stopCamera(): void {
    if (animationFrame !== null) cancelAnimationFrame(animationFrame); animationFrame = null;
    stream.value?.getTracks().forEach((track) => track.stop()); stream.value = null;
    handLandmarker.value?.close(); handLandmarker.value = null;
    faceLandmarker.value?.close(); faceLandmarker.value = null;
    recentByHand.clear(); eyeMotion.splice(0); captureFrames.splice(0); capturing = false; captureToken += 1;
    if (captureTimer !== null) window.clearTimeout(captureTimer); captureTimer = null; captureTarget.value = null;
    tracking.value = false; faceTracking.value = false; handCount.value = 0; inferenceMs.value = 0;
    cameraStatus.value = "off"; cameraMessage.value = "Camera stopped. No camera frames were saved or uploaded.";
    prediction.value = { gestureId: null, confidence: 0, inDistribution: false }; handPredictions.value = [];
    visionSignals.value = { ...visionSignals.value, handCount: 0, facePresent: false, faceModelReady: false, cue: "neutral", note: "Camera is off." };
    machine.reset(); intent.value = machine.snapshot(); setupCanvas();
  }

  function captureGesture(gesture: Gesture): void {
    if (cameraStatus.value !== "ready" || !tracking.value || capturing) { captureMessage.value = "Start the camera and keep at least one hand visible before capturing."; return; }
    capturing = true; captureFrames.splice(0); const token = ++captureToken; captureTarget.value = gesture.id;
    captureMessage.value = `Hold “${gesture.name}” naturally for one second with the hand you prefer…`;
    captureTimer = window.setTimeout(async () => {
      if (captureToken !== token) return;
      captureTimer = null; capturing = false; captureTarget.value = null;
      const sequence = resampleSequence(captureFrames); captureFrames.splice(0);
      if (!sequence) { captureMessage.value = "Capture was too short or tracking was interrupted. Please try again."; return; }
      const next = { ...store.profile, updatedAt: new Date().toISOString(), gestures: store.profile.gestures.map((item) => item.id === gesture.id
        ? { ...item, samples: [...item.samples, { raw: sequence, session: "vue-local-session", capturedAt: new Date().toISOString() }].slice(-48) } : item) };
      try { await store.saveProfile(next); await store.clearModel(); captureMessage.value = `Captured “${gesture.name}”. Repeat from another comfortable angle or hand.`; }
      catch { captureMessage.value = "Capture could not be saved. Device storage is required before calibration can change."; }
    }, 1_050);
  }

  async function trainLocalModel(): Promise<boolean> {
    try {
      const fingerprint = await profileModelFingerprint(store.profile); const trained = trainPrototypeModel(store.profile.gestures, fingerprint);
      await store.activateModel(trained); machine.reset(); captureMessage.value = "On-device personal gesture model trained. Recognition is ready."; stopCamera(); return true;
    } catch (error) { captureMessage.value = error instanceof Error ? error.message : "Could not train the on-device model."; return false; }
  }

  onBeforeUnmount(() => { stopCamera(); communication.dispose(); });

  return {
    videoEl, canvasEl, cameraStatus, cameraMessage, tracking, faceTracking, handCount, inferenceMs,
    captureTarget, captureMessage, prediction, handPredictions, visionSignals, intent, currentGesture,
    voiceMessage: communication.voiceMessage, armedGestureId: communication.armedGestureId,
    touchPhrase: communication.touchPhrase, speakPhrase: communication.speakPhrase,
    startCamera, stopCamera, captureGesture, trainLocalModel,
  };
}
