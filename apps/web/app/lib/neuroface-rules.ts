/**
 * NeuroFace Sense rules for the NeuroBridge Asha web app.
 *
 * Replaces the old single-gesture face mode with four auto-calibrated
 * patient communication rules built from the NeuroFace Sense pipeline
 * (MediaPipe Face Mesh geometry + a per-patient neutral baseline twin):
 *
 * - 5 blinks in a row            -> "I want water"
 * - sustained smile              -> "I am feeling good"
 * - sustained abnormality        -> "Emergency help needed"
 *   (lateral lip deviation, or a pain/distress movement pattern)
 * - 5 rightward head turns       -> "Give me some food"
 *
 * Calibration is fully automatic: the first 60 face frames (~2 seconds of
 * relaxed face) become the patient's neutral baseline. No manual step.
 *
 * Movement-pattern detection only — this module reports sustained,
 * deliberate or involuntary movement patterns. It never diagnoses.
 */

export const NEUROFACE_RULE_IDS = [
  "water-5-blinks",
  "feeling-good-smile",
  "emergency-abnormality",
  "food-5-head-right",
] as const;

export type NeuroFaceRuleId = (typeof NEUROFACE_RULE_IDS)[number];

export const NEUROFACE_RULE_LABELS: Record<NeuroFaceRuleId, string> = Object.freeze({
  "water-5-blinks": "Blink 5 times",
  "feeling-good-smile": "Smile",
  "emergency-abnormality": "Abnormality alert",
  "food-5-head-right": "Head right 5 times",
});

export const NEUROFACE_RULE_PHRASES: Record<NeuroFaceRuleId, string> = Object.freeze({
  "water-5-blinks": "I want water",
  "feeling-good-smile": "I am feeling good",
  "emergency-abnormality": "Emergency help needed",
  "food-5-head-right": "Give me some food",
});

/** Default profile-gesture bindings; null falls back to the built-in phrase. */
export const DEFAULT_NEUROFACE_BINDINGS: Record<NeuroFaceRuleId, string | null> = Object.freeze({
  "water-5-blinks": "water",
  "feeling-good-smile": null,
  "emergency-abnormality": "emergency",
  "food-5-head-right": null,
});

export type NeuroFacePoint = { x: number; y: number };

export type NeuroFaceTwin = {
  version: 1;
  sampleCount: number;
  /** Mean open-eye EAR from the auto-calibration window. */
  earMean: number;
  /** Neutral mouth width (normalized units). */
  mouthW: number;
  /** Neutral lip-deviation offset (mouth centre vs nose axis, face widths). */
  dev0: number;
  /** Neutral head pose, degrees. */
  yawDeg: number;
  pitchDeg: number;
};

export type NeuroFaceMetrics = {
  facePresent: boolean;
  earAvg: number;
  smile: number;
  /** Signed lateral deviation, face widths. + = patient right. */
  lateralDeviation: number;
  /** Baseline-relative yaw/pitch, degrees. */
  yawDeg: number;
  pitchDeg: number;
  /** 0..1 pain/distress movement composite. */
  painScore: number;
};

export type NeuroFaceTrigger = {
  rule: NeuroFaceRuleId;
  at: number;
  confidence: number;
  detail: string;
};

export type NeuroFaceStatus = {
  calibrated: boolean;
  calibrationProgress: number;
  lastTrigger: NeuroFaceTrigger | null;
  metrics: NeuroFaceMetrics | null;
};

/* Tuning: mirrors the proven mobile clinical runtime. */
const AUTO_CAL_FRAMES = 60;
const BLINK_WINDOW_MS = 4_000;
const BLINKS_FOR_WATER = 5;
const BLINK_MIN_DUR_S = 0.06;
const BLINK_MAX_DUR_S = 0.65;
const SMILE_THRESHOLD = 0.4;
const SMILE_HOLD_MS = 800;
const SMILE_COOLDOWN_MS = 4_000;
const DEV_THRESHOLD = 0.035;
const DEV_RELEASE = 0.02;
const DEV_HOLD_MS = 4_000;
const DEV_YAW_GATE_DEG = 14;
const PAIN_THRESHOLD = 0.6;
const PAIN_RELEASE = 0.4;
const PAIN_HOLD_MS = 3_000;
const HEAD_RIGHT_ENTER_DEG = 12;
const HEAD_RIGHT_EXIT_DEG = 6;
const HEAD_TURNS_FOR_FOOD = 5;
const HEAD_WINDOW_MS = 6_000;
const ABNORMALITY_RECOOLDOWN_MS = 10_000;

const IDX = Object.freeze({
  eyeLOuter: 33, eyeLInner: 133, eyeLUp1: 160, eyeLUp2: 158, eyeLLow1: 153, eyeLLow2: 144,
  eyeROuter: 263, eyeRInner: 362, eyeRUp1: 385, eyeRUp2: 387, eyeRLow1: 373, eyeRLow2: 380,
  noseTip: 1, chin: 152, forehead: 10, cheekL: 234, cheekR: 454,
  mouthL: 61, mouthR: 291, lipUp: 13, lipLow: 14,
});

function dist(a: NeuroFacePoint, b: NeuroFacePoint): number {
  return Math.hypot(a.x - b.x, a.y - b.y);
}

function eyeAspect(landmarks: ReadonlyArray<NeuroFacePoint>, outer: number, inner: number, up1: number, up2: number, low1: number, low2: number): number {
  const vertical = dist(landmarks[up1], landmarks[low1]) + dist(landmarks[up2], landmarks[low2]);
  const horizontal = Math.max(1e-6, dist(landmarks[outer], landmarks[inner]) * 2);
  return vertical / horizontal;
}

function hasLandmarks(landmarks: ReadonlyArray<NeuroFacePoint>): boolean {
  if (!Array.isArray(landmarks) || landmarks.length < 478) return false;
  for (const index of [33, 133, 263, 362, 1, 10, 152, 234, 454, 61, 291, 13, 14] as const) {
    const point = landmarks[index];
    if (!point || !Number.isFinite(point.x) || !Number.isFinite(point.y)) return false;
  }
  return true;
}

/**
 * Pure geometric metrics from full-face landmarks. Safe to call every frame;
 * returns facePresent=false metrics when tracking is lost.
 */
export function extractNeuroFaceMetrics(
  landmarks: ReadonlyArray<NeuroFacePoint> | null | undefined,
  twin: NeuroFaceTwin | null,
): NeuroFaceMetrics {
  if (!landmarks || !hasLandmarks(landmarks)) {
    return { facePresent: false, earAvg: 0, smile: 0, lateralDeviation: 0, yawDeg: 0, pitchDeg: 0, painScore: 0 };
  }
  const earAvg = (eyeAspect(landmarks, IDX.eyeLOuter, IDX.eyeLInner, IDX.eyeLUp1, IDX.eyeLUp2, IDX.eyeLLow1, IDX.eyeLLow2)
    + eyeAspect(landmarks, IDX.eyeROuter, IDX.eyeRInner, IDX.eyeRUp1, IDX.eyeRUp2, IDX.eyeRLow1, IDX.eyeRLow2)) / 2;

  const mouthW = Math.max(1e-6, dist(landmarks[IDX.mouthL], landmarks[IDX.mouthR]));
  const mouthW0 = twin?.mouthW && twin.mouthW > 0 ? twin.mouthW : mouthW;
  const stretch = Math.max(0, Math.min(1, (mouthW / mouthW0 - 1) * 4));
  const midY = (landmarks[IDX.lipUp].y + landmarks[IDX.lipLow].y) / 2;
  const lift = Math.max(0, Math.min(1, ((midY - landmarks[IDX.mouthL].y) + (midY - landmarks[IDX.mouthR].y)) / mouthW * 1.1));
  const smile = Math.max(0, Math.min(1, stretch * 0.55 + lift * 0.45));

  const faceW = Math.max(1e-6, dist(landmarks[IDX.cheekL], landmarks[IDX.cheekR]));
  const mouthCx = (landmarks[IDX.mouthL].x + landmarks[IDX.mouthR].x) / 2;
  const lateralDeviation = (mouthCx - landmarks[IDX.noseTip].x) / faceW - (twin?.dev0 ?? 0);

  const faceH = Math.max(1e-6, dist(landmarks[IDX.forehead], landmarks[IDX.chin]));
  const midX = (landmarks[IDX.cheekL].x + landmarks[IDX.cheekR].x) / 2;
  const midEyeY = (landmarks[IDX.eyeLOuter].y + landmarks[IDX.eyeROuter].y) / 2;
  const yawDeg = ((landmarks[IDX.noseTip].x - midX) / faceW) * 130 - (twin?.yawDeg ?? 0);
  const pitchDeg = ((landmarks[IDX.noseTip].y - midEyeY) / faceH) * 120 - 8 - (twin?.pitchDeg ?? 0);

  const mar = dist(landmarks[IDX.lipUp], landmarks[IDX.lipLow]) / mouthW;
  const squint = Math.max(0, Math.min(1, (0.28 - earAvg) * 4));
  const tension = Math.max(0, Math.min(1, (0.09 - mar) * 6));
  const depressNorm = Math.max(0, Math.min(1, (((landmarks[IDX.mouthL].y + landmarks[IDX.mouthR].y) / 2 - midY) / faceW) / 0.03));
  const painScore = Math.max(0, Math.min(1, 0.35 * squint + 0.35 * tension + 0.3 * depressNorm));

  return { facePresent: true, earAvg, smile, lateralDeviation, yawDeg, pitchDeg, painScore };
}

/** Automatic neutral-baseline collector: feed relaxed-face frames, no user step. */
export class NeuroFaceAutoCalibrator {
  private ear = 0;
  private mouthW = 0;
  private dev = 0;
  private yaw = 0;
  private pitch = 0;
  private count = 0;

  constructor(readonly requiredFrames: number = AUTO_CAL_FRAMES) {
    if (!Number.isInteger(requiredFrames) || requiredFrames < 1) throw new Error("requiredFrames must be a positive integer.");
  }

  add(landmarks: ReadonlyArray<NeuroFacePoint> | null | undefined): boolean {
    const metrics = extractNeuroFaceMetrics(landmarks, null);
    if (!metrics.facePresent) return false;
    // Raw (twin-less) accumulators: ear and mouth width are absolute here.
    const rawEar = metrics.earAvg;
    const rawW = rawMouthWidth(landmarks as ReadonlyArray<NeuroFacePoint>);
    const rawDev = rawDeviation(landmarks as ReadonlyArray<NeuroFacePoint>);
    const rawPose = rawHeadPose(landmarks as ReadonlyArray<NeuroFacePoint>);
    this.ear += rawEar;
    this.mouthW += rawW;
    this.dev += rawDev;
    this.yaw += rawPose.yaw;
    this.pitch += rawPose.pitch;
    this.count += 1;
    return true;
  }

  get acceptedFrames(): number {
    return this.count;
  }

  get progress(): number {
    return Math.min(1, this.count / this.requiredFrames);
  }

  get ready(): boolean {
    return this.count >= this.requiredFrames;
  }

  finish(): NeuroFaceTwin {
    if (!this.ready) throw new Error(`Auto-calibration needs ${this.requiredFrames} face frames; got ${this.count}.`);
    return {
      version: 1,
      sampleCount: this.count,
      earMean: this.ear / this.count,
      mouthW: this.mouthW / this.count,
      dev0: this.dev / this.count,
      yawDeg: this.yaw / this.count,
      pitchDeg: this.pitch / this.count,
    };
  }

  reset(): void {
    this.ear = 0; this.mouthW = 0; this.dev = 0; this.yaw = 0; this.pitch = 0; this.count = 0;
  }
}

function rawMouthWidth(landmarks: ReadonlyArray<NeuroFacePoint>): number {
  return Math.max(1e-6, dist(landmarks[IDX.mouthL], landmarks[IDX.mouthR]));
}

function rawDeviation(landmarks: ReadonlyArray<NeuroFacePoint>): number {
  const faceW = Math.max(1e-6, dist(landmarks[IDX.cheekL], landmarks[IDX.cheekR]));
  return ((landmarks[IDX.mouthL].x + landmarks[IDX.mouthR].x) / 2 - landmarks[IDX.noseTip].x) / faceW;
}

function rawHeadPose(landmarks: ReadonlyArray<NeuroFacePoint>): { yaw: number; pitch: number } {
  const faceW = Math.max(1e-6, dist(landmarks[IDX.cheekL], landmarks[IDX.cheekR]));
  const faceH = Math.max(1e-6, dist(landmarks[IDX.forehead], landmarks[IDX.chin]));
  const midX = (landmarks[IDX.cheekL].x + landmarks[IDX.cheekR].x) / 2;
  const midEyeY = (landmarks[IDX.eyeLOuter].y + landmarks[IDX.eyeROuter].y) / 2;
  return {
    yaw: ((landmarks[IDX.noseTip].x - midX) / faceW) * 130,
    pitch: ((landmarks[IDX.noseTip].y - midEyeY) / faceH) * 120 - 8,
  };
}

/**
 * The four auto-calibrated patient rules. Feed landmarks + a millisecond
 * timestamp per video frame; reads `trigger` when a rule fires.
 */
export class NeuroFaceRuleEngine {
  private twin: NeuroFaceTwin | null;
  private blinkClosed = false;
  private blinkT0 = 0;
  private recentBlinks: number[] = [];
  private smileHoldMs = 0;
  private lastSmileAt = Number.NEGATIVE_INFINITY;
  private devHoldMs = 0;
  private painHoldMs = 0;
  private lastAbnormalityAt = Number.NEGATIVE_INFINITY;
  private headRightArmed = false;
  private recentHeadTurns: number[] = [];
  private lastNow = Number.NEGATIVE_INFINITY;
  private lastTrigger: NeuroFaceTrigger | null = null;
  private lastMetrics: NeuroFaceMetrics | null = null;

  constructor(twin: NeuroFaceTwin | null = null) {
    this.twin = twin;
  }

  setTwin(twin: NeuroFaceTwin): void {
    this.twin = twin;
    this.resetDetectors();
  }

  reset(): void {
    this.twin = null;
    this.resetDetectors();
    this.lastTrigger = null;
    this.lastMetrics = null;
    this.lastNow = Number.NEGATIVE_INFINITY;
  }

  snapshot(): NeuroFaceStatus {
    return {
      calibrated: this.twin !== null,
      calibrationProgress: this.twin ? 1 : 0,
      lastTrigger: this.lastTrigger ? { ...this.lastTrigger } : null,
      metrics: this.lastMetrics ? { ...this.lastMetrics } : null,
    };
  }

  step(landmarks: ReadonlyArray<NeuroFacePoint> | null | undefined, now: number): { status: NeuroFaceStatus; trigger: NeuroFaceTrigger | null } {
    if (!Number.isFinite(now)) throw new Error("NeuroFace timestamps must be finite.");
    const at = Math.max(now, this.lastNow === Number.NEGATIVE_INFINITY ? now : this.lastNow);
    const dtMs = this.lastNow === Number.NEGATIVE_INFINITY ? 0 : Math.min(500, Math.max(0, at - this.lastNow));
    this.lastNow = at;
    const metrics = extractNeuroFaceMetrics(landmarks, this.twin);
    this.lastMetrics = { ...metrics };
    if (!this.twin || !metrics.facePresent) {
      if (!metrics.facePresent) this.resetTransient();
      const status = this.snapshot();
      return { status, trigger: null };
    }
    const trigger = this.detect(metrics, at, dtMs);
    if (trigger) this.lastTrigger = { ...trigger };
    return { status: this.snapshot(), trigger };
  }

  private detect(metrics: NeuroFaceMetrics, at: number, dtMs: number): NeuroFaceTrigger | null {
    // Rule 1: 5 blinks in a row -> "I want water".
    const baseEar = this.twin && this.twin.earMean > 0 ? this.twin.earMean : 0.27;
    const thClose = Math.max(0.12, baseEar * 0.55);
    const thOpen = Math.max(0.16, baseEar * 0.8);
    if (!this.blinkClosed && metrics.earAvg < thClose) {
      this.blinkClosed = true;
      this.blinkT0 = at / 1000;
    } else if (this.blinkClosed && metrics.earAvg > thOpen) {
      this.blinkClosed = false;
      const durS = at / 1000 - this.blinkT0;
      if (durS >= BLINK_MIN_DUR_S && durS <= BLINK_MAX_DUR_S) {
        this.recentBlinks.push(at);
        this.recentBlinks = this.recentBlinks.filter((blinkAt) => at - blinkAt <= BLINK_WINDOW_MS);
        if (this.recentBlinks.length >= BLINKS_FOR_WATER) {
          this.recentBlinks = [];
          return this.fire("water-5-blinks", at, 0.95, `${BLINKS_FOR_WATER} consecutive blinks`);
        }
      }
    }

    // Rule 2: sustained smile -> "I am feeling good".
    if (metrics.smile > SMILE_THRESHOLD) {
      this.smileHoldMs += dtMs;
      if (this.smileHoldMs >= SMILE_HOLD_MS && at - this.lastSmileAt > SMILE_COOLDOWN_MS) {
        this.lastSmileAt = at;
        this.smileHoldMs = -1500;
        return this.fire("feeling-good-smile", at, 0.9, `smile held ${(SMILE_HOLD_MS / 1000).toFixed(1)}s`);
      }
    } else {
      this.smileHoldMs = 0;
    }

    // Rule 3: sustained abnormality -> "Emergency help needed".
    const devMag = Math.abs(metrics.lateralDeviation);
    if (devMag >= DEV_THRESHOLD && Math.abs(metrics.yawDeg) < DEV_YAW_GATE_DEG) {
      this.devHoldMs += dtMs;
    } else if (devMag < DEV_RELEASE) {
      this.devHoldMs = 0;
    }
    if (metrics.painScore >= PAIN_THRESHOLD) {
      this.painHoldMs += dtMs;
    } else if (metrics.painScore < PAIN_RELEASE) {
      this.painHoldMs = 0;
    }
    if ((this.devHoldMs >= DEV_HOLD_MS || this.painHoldMs >= PAIN_HOLD_MS) && at - this.lastAbnormalityAt > ABNORMALITY_RECOOLDOWN_MS) {
      this.lastAbnormalityAt = at;
      const reason = this.devHoldMs >= DEV_HOLD_MS
        ? `lateral deviation ${(devMag * 100).toFixed(1)}%`
        : `distress movement ${(metrics.painScore * 100).toFixed(0)}%`;
      return this.fire("emergency-abnormality", at, 0.9, reason);
    }

    // Rule 4: 5 rightward head turns -> "Give me some food".
    if (metrics.yawDeg > HEAD_RIGHT_ENTER_DEG) {
      this.headRightArmed = true;
    } else if (this.headRightArmed && metrics.yawDeg < HEAD_RIGHT_EXIT_DEG) {
      this.headRightArmed = false;
      this.recentHeadTurns.push(at);
      this.recentHeadTurns = this.recentHeadTurns.filter((turnAt) => at - turnAt <= HEAD_WINDOW_MS);
      if (this.recentHeadTurns.length >= HEAD_TURNS_FOR_FOOD) {
        this.recentHeadTurns = [];
        return this.fire("food-5-head-right", at, 0.9, `${HEAD_TURNS_FOR_FOOD} rightward turns`);
      }
    } else if (metrics.yawDeg < -HEAD_RIGHT_ENTER_DEG) {
      this.headRightArmed = false;
    }
    return null;
  }

  private fire(rule: NeuroFaceRuleId, at: number, confidence: number, detail: string): NeuroFaceTrigger {
    return { rule, at, confidence, detail };
  }

  private resetTransient(): void {
    this.blinkClosed = false;
    this.headRightArmed = false;
  }

  private resetDetectors(): void {
    this.resetTransient();
    this.recentBlinks = [];
    this.smileHoldMs = 0;
    this.lastSmileAt = Number.NEGATIVE_INFINITY;
    this.devHoldMs = 0;
    this.painHoldMs = 0;
    this.lastAbnormalityAt = Number.NEGATIVE_INFINITY;
    this.recentHeadTurns = [];
  }
}
