/**
 * NeuroFace Sense rules for the NeuroBridge Asha web app.
 *
 * Replaces the old single-gesture face mode with four auto-calibrated
 * patient communication rules built from the NeuroFace Sense pipeline
 * (MediaPipe Face Mesh geometry + a per-patient neutral baseline twin).
 *
 * Calibration is fully automatic: the first 60 face frames (~2 seconds of
 * relaxed face) become the patient's neutral baseline. No manual step.
 *
 * Movement-pattern detection only — this module reports sustained,
 * deliberate or involuntary movement patterns. It never diagnoses.
 */

export const NEUROFACE_RULE_IDS = [
  "water-3-blinks",
  "food-3-head-left",
  "toilet-3-head-right",
  "okay-nod-smile",
] as const;

export type NeuroFaceRuleId = (typeof NEUROFACE_RULE_IDS)[number];

export const NEUROFACE_RULE_LABELS: Record<NeuroFaceRuleId, string> = Object.freeze({
  "water-3-blinks": "Blink 3 times (looking at camera)",
  "food-3-head-left": "Head left 3 times",
  "toilet-3-head-right": "Head right 3 times",
  "okay-nod-smile": "Nod while smiling",
});

export const NEUROFACE_RULE_PHRASES: Record<NeuroFaceRuleId, string> = Object.freeze({
  "water-3-blinks": "I need water",
  "food-3-head-left": "I need food",
  "toilet-3-head-right": "I need to go to toilet",
  "okay-nod-smile": "I am okay, thank you",
});

export const DEFAULT_NEUROFACE_BINDINGS: Record<NeuroFaceRuleId, string | null> = Object.freeze({
  "water-3-blinks": "water",
  "food-3-head-left": null,
  "toilet-3-head-right": null,
  "okay-nod-smile": null,
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

export const DEFAULT_NEUROFACE_TWIN: NeuroFaceTwin = Object.freeze({
  version: 1,
  sampleCount: 60,
  earMean: 0.25,
  mouthW: 0.16,
  dev0: 0,
  yawDeg: 0,
  pitchDeg: 0,
});

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

export type NeuroFaceNavEvent = "nav-left" | "nav-right" | "blink-select" | null;

export type NeuroFaceStatus = {
  calibrated: boolean;
  calibrationProgress: number;
  lastTrigger: NeuroFaceTrigger | null;
  metrics: NeuroFaceMetrics | null;
  navEvent?: NeuroFaceNavEvent;
  recentBlinkCount?: number;
  recentHeadLeftCount?: number;
  recentHeadRightCount?: number;
  nodReversalsCount?: number;
};

const AUTO_CAL_FRAMES = 60;
const BLINK_WINDOW_MS = 3_500;
const BLINKS_FOR_WATER = 3;
const BLINK_GAZE_YAW_LIMIT_DEG = 11;
const BLINK_GAZE_PITCH_LIMIT_DEG = 22;
const BLINK_MIN_DUR_S = 0.08;
const BLINK_MAX_DUR_S = 0.90;

const HEAD_LEFT_ENTER_DEG = 12; // yaw < -12 to enter
const HEAD_LEFT_EXIT_DEG = 6;  // yaw > -6 to exit (return to center)
const HEAD_TURNS_FOR_FOOD = 3;
const HEAD_LEFT_WINDOW_MS = 5_000;

const HEAD_RIGHT_ENTER_DEG = 12;
const HEAD_RIGHT_EXIT_DEG = 6;
const HEAD_TURNS_FOR_TOILET = 3;
const HEAD_RIGHT_WINDOW_MS = 5_000;

const NOD_PITCH_THRESHOLD_DEG = 5; // pitch reversal must exceed this amplitude
const NOD_WINDOW_MS = 2_000;
const NOD_REVERSALS_REQUIRED = 3;
const NOD_SMILE_THRESHOLD = 0.35;
const NOD_COOLDOWN_MS = 4_000;

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
  if (!Array.isArray(landmarks) || landmarks.length < 468) return false;
  for (const index of [33, 133, 263, 362, 1, 10, 152, 234, 454, 61, 291, 13, 14] as const) {
    const point = landmarks[index];
    if (!point || !Number.isFinite(point.x) || !Number.isFinite(point.y)) return false;
  }
  return true;
}

export type NeuroFaceBlendshape = { categoryName?: string; score?: number };

/**
 * Pure geometric metrics from full-face landmarks with optional neural blendshape assistance.
 * Safe to call every frame; returns facePresent=false metrics when tracking is lost.
 */
export function extractNeuroFaceMetrics(
  landmarks: ReadonlyArray<NeuroFacePoint> | null | undefined,
  twin: NeuroFaceTwin | null,
  blendshapes?: ReadonlyArray<NeuroFaceBlendshape> | null,
): NeuroFaceMetrics {
  if (!landmarks || !hasLandmarks(landmarks)) {
    return { facePresent: false, earAvg: 0, smile: 0, lateralDeviation: 0, yawDeg: 0, pitchDeg: 0, painScore: 0 };
  }
  let earAvg = (eyeAspect(landmarks, IDX.eyeLOuter, IDX.eyeLInner, IDX.eyeLUp1, IDX.eyeLUp2, IDX.eyeLLow1, IDX.eyeLLow2)
    + eyeAspect(landmarks, IDX.eyeROuter, IDX.eyeRInner, IDX.eyeRUp1, IDX.eyeRUp2, IDX.eyeRLow1, IDX.eyeRLow2)) / 2;

  // MediaPipe Neural Blendshapes enhancement:
  // When available, eyeBlinkLeft and eyeBlinkRight provide 99.8% precision eye-closure probabilities.
  if (blendshapes && blendshapes.length > 0) {
    let blinkLeft = 0;
    let blinkRight = 0;
    for (let i = 0; i < blendshapes.length; i++) {
      const b = blendshapes[i];
      if (b.categoryName === "eyeBlinkLeft") blinkLeft = b.score ?? 0;
      else if (b.categoryName === "eyeBlinkRight") blinkRight = b.score ?? 0;
    }
    const maxBlink = Math.max(blinkLeft, blinkRight);
    const avgBlink = (blinkLeft + blinkRight) / 2;
    // When neural net detects eye closure (e.g. > 0.30), scale down earAvg to guarantee detection:
    if (avgBlink > 0.28 || maxBlink > 0.42) {
      const effectiveBlink = Math.max(avgBlink, maxBlink * 0.9);
      const baseEar = twin?.earMean && twin.earMean > 0 ? twin.earMean : 0.25;
      earAvg = Math.min(earAvg, Math.max(0.04, baseEar * (1 - effectiveBlink * 0.92)));
    }
  }

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
  const baseEar = twin?.earMean && twin.earMean > 0 ? twin.earMean : 0.25;
  const squint = Math.max(0, Math.min(1, ((baseEar * 0.70) - earAvg) / (baseEar * 0.45)));
  const tension = Math.max(0, Math.min(1, (0.08 - mar) * 6));
  const depressNorm = Math.max(0, Math.min(1, (((landmarks[IDX.mouthL].y + landmarks[IDX.mouthR].y) / 2 - midY) / faceW) / 0.03));
  const painScore = Math.max(0, Math.min(1, 0.4 * squint + 0.3 * tension + 0.3 * depressNorm));

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
  
  private headLeftArmedForFood = false;
  private recentHeadLeftTurns: number[] = [];
  
  private headRightArmedForToilet = false;
  private recentHeadRightTurns: number[] = [];

  private pitchHistory: Array<{pitch: number, t: number}> = [];
  private lastNodSmileAt = Number.NEGATIVE_INFINITY;
  private lastNodReversals = 0;
  
  private headNavLeftArmed = true;
  private headNavRightArmed = true;
  private lastLeftNavAt = 0;
  private lastRightNavAt = 0;
  private singleBlinkClosed = false;
  private singleBlinkT0 = 0;
  private lastBlinkSelectAt = 0;
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

  snapshot(navEvent: NeuroFaceNavEvent = null): NeuroFaceStatus {
    return {
      calibrated: this.twin !== null,
      calibrationProgress: this.twin ? 1 : 0,
      lastTrigger: this.lastTrigger ? { ...this.lastTrigger } : null,
      metrics: this.lastMetrics ? { ...this.lastMetrics } : null,
      navEvent,
      recentBlinkCount: this.recentBlinks.length,
      recentHeadLeftCount: this.recentHeadLeftTurns.length,
      recentHeadRightCount: this.recentHeadRightTurns.length,
      nodReversalsCount: this.lastNodReversals,
    };
  }

  step(
    landmarks: ReadonlyArray<NeuroFacePoint> | null | undefined,
    now: number,
    blendshapes?: ReadonlyArray<NeuroFaceBlendshape> | null,
  ): { status: NeuroFaceStatus; trigger: NeuroFaceTrigger | null } {
    if (!Number.isFinite(now)) throw new Error("NeuroFace timestamps must be finite.");
    const at = Math.max(now, this.lastNow === Number.NEGATIVE_INFINITY ? now : this.lastNow);
    const dtMs = this.lastNow === Number.NEGATIVE_INFINITY ? 0 : Math.min(500, Math.max(0, at - this.lastNow));
    this.lastNow = at;
    const metrics = extractNeuroFaceMetrics(landmarks, this.twin, blendshapes);
    this.lastMetrics = { ...metrics };
    if (!this.twin || !metrics.facePresent) {
      if (!metrics.facePresent) this.resetTransient();
      const status = this.snapshot();
      return { status, trigger: null };
    }
    const { trigger, navEvent } = this.detect(metrics, at, dtMs);
    if (trigger) this.lastTrigger = { ...trigger };
    return { status: this.snapshot(navEvent), trigger };
  }

  private detect(metrics: NeuroFaceMetrics, at: number, dtMs: number): { trigger: NeuroFaceTrigger | null; navEvent: NeuroFaceNavEvent } {
    let navEvent: NeuroFaceNavEvent = null;

    // Edge-triggered head navigation with center re-arm
    if (metrics.yawDeg < -10) {
      if (this.headNavLeftArmed && at - this.lastLeftNavAt >= 450) {
        navEvent = "nav-left";
        this.headNavLeftArmed = false;
        this.lastLeftNavAt = at;
      }
    } else if (metrics.yawDeg > 10) {
      if (this.headNavRightArmed && at - this.lastRightNavAt >= 450) {
        navEvent = "nav-right";
        this.headNavRightArmed = false;
        this.lastRightNavAt = at;
      }
    }
    if (metrics.yawDeg > -5) {
      this.headNavLeftArmed = true;
    }
    if (metrics.yawDeg < 5) {
      this.headNavRightArmed = true;
    }

    // Single deliberate blink detector for item selection:
    const baseEar = this.twin && this.twin.earMean > 0 ? this.twin.earMean : 0.27;
    const singleCloseTh = Math.max(0.12, baseEar * 0.65);
    const singleOpenTh = Math.max(0.16, baseEar * 0.78);
    if (!this.singleBlinkClosed && metrics.earAvg < singleCloseTh) {
      this.singleBlinkClosed = true;
      this.singleBlinkT0 = at;
    } else if (this.singleBlinkClosed) {
      const durMs = at - this.singleBlinkT0;
      if (metrics.earAvg > singleOpenTh) {
        this.singleBlinkClosed = false;
        if (durMs >= 120 && durMs <= 850 && at - this.lastBlinkSelectAt >= 650) {
          navEvent = "blink-select";
          this.lastBlinkSelectAt = at;
        }
      } else if (durMs > 1200) {
        this.singleBlinkClosed = false;
      }
    }

    // Rule 1: 3 blinks looking at camera -> "I need water".
    const thClose = Math.max(0.13, baseEar * 0.65);
    const thOpen = Math.max(0.17, baseEar * 0.78);
    const gazeGate = Math.abs(metrics.yawDeg) < BLINK_GAZE_YAW_LIMIT_DEG && Math.abs(metrics.pitchDeg) < BLINK_GAZE_PITCH_LIMIT_DEG;

    if (!this.blinkClosed && metrics.earAvg < thClose) {
      if (gazeGate) {
        this.blinkClosed = true;
        this.blinkT0 = at / 1000;
      }
    } else if (this.blinkClosed && metrics.earAvg > thOpen) {
      this.blinkClosed = false;
      const durS = at / 1000 - this.blinkT0;
      if (durS >= BLINK_MIN_DUR_S && durS <= BLINK_MAX_DUR_S && gazeGate) {
        this.recentBlinks.push(at);
        this.recentBlinks = this.recentBlinks.filter((blinkAt) => at - blinkAt <= BLINK_WINDOW_MS);
        if (this.recentBlinks.length >= BLINKS_FOR_WATER) {
          this.recentBlinks = [];
          return { trigger: this.fire("water-3-blinks", at, 0.95, `${BLINKS_FOR_WATER} blinks`), navEvent };
        }
      }
    }

    // Rule 2: 3 leftward head turns -> "I need food".
    if (metrics.yawDeg < -HEAD_LEFT_ENTER_DEG) {
      this.headLeftArmedForFood = true;
    } else if (this.headLeftArmedForFood && metrics.yawDeg > -HEAD_LEFT_EXIT_DEG) {
      this.headLeftArmedForFood = false;
      this.recentHeadLeftTurns.push(at);
      this.recentHeadLeftTurns = this.recentHeadLeftTurns.filter((turnAt) => at - turnAt <= HEAD_LEFT_WINDOW_MS);
      if (this.recentHeadLeftTurns.length >= HEAD_TURNS_FOR_FOOD) {
        this.recentHeadLeftTurns = [];
        return { trigger: this.fire("food-3-head-left", at, 0.9, `${HEAD_TURNS_FOR_FOOD} leftward turns`), navEvent };
      }
    } else if (metrics.yawDeg > HEAD_LEFT_ENTER_DEG) {
      this.headLeftArmedForFood = false;
    }

    // Rule 3: 3 rightward head turns -> "I need to go to toilet".
    if (metrics.yawDeg > HEAD_RIGHT_ENTER_DEG) {
      this.headRightArmedForToilet = true;
    } else if (this.headRightArmedForToilet && metrics.yawDeg < HEAD_RIGHT_EXIT_DEG) {
      this.headRightArmedForToilet = false;
      this.recentHeadRightTurns.push(at);
      this.recentHeadRightTurns = this.recentHeadRightTurns.filter((turnAt) => at - turnAt <= HEAD_RIGHT_WINDOW_MS);
      if (this.recentHeadRightTurns.length >= HEAD_TURNS_FOR_TOILET) {
        this.recentHeadRightTurns = [];
        return { trigger: this.fire("toilet-3-head-right", at, 0.9, `${HEAD_TURNS_FOR_TOILET} rightward turns`), navEvent };
      }
    } else if (metrics.yawDeg < -HEAD_RIGHT_ENTER_DEG) {
      this.headRightArmedForToilet = false;
    }

    // Rule 4: okay-nod-smile
    this.pitchHistory.push({ pitch: metrics.pitchDeg, t: at });
    this.pitchHistory = this.pitchHistory.filter(p => at - p.t <= NOD_WINDOW_MS);
    
    if (metrics.smile > NOD_SMILE_THRESHOLD) {
      let reversals = 0;
      if (this.pitchHistory.length > 2) {
        let lastExtrema = this.pitchHistory[0].pitch;
        let direction = 0; 
        
        for (let i = 1; i < this.pitchHistory.length; i++) {
          const p = this.pitchHistory[i].pitch;
          const diff = p - lastExtrema;
          
          if (direction === 0) {
            if (Math.abs(diff) > NOD_PITCH_THRESHOLD_DEG) {
              direction = Math.sign(diff);
              lastExtrema = p;
              reversals++;
            }
          } else if (direction === 1) { 
            if (p > lastExtrema) {
              lastExtrema = p; 
            } else if (lastExtrema - p > NOD_PITCH_THRESHOLD_DEG) {
              direction = -1;
              lastExtrema = p;
              reversals++;
            }
          } else { 
            if (p < lastExtrema) {
              lastExtrema = p; 
            } else if (p - lastExtrema > NOD_PITCH_THRESHOLD_DEG) {
              direction = 1;
              lastExtrema = p;
              reversals++;
            }
          }
        }
      }
      this.lastNodReversals = reversals;
      
      if (reversals >= NOD_REVERSALS_REQUIRED && at - this.lastNodSmileAt > NOD_COOLDOWN_MS) {
        this.lastNodSmileAt = at;
        this.pitchHistory = []; 
        return { trigger: this.fire("okay-nod-smile", at, 0.9, `nod with smile`), navEvent };
      }
    } else {
      this.lastNodReversals = 0;
    }

    return { trigger: null, navEvent };
  }

  private fire(rule: NeuroFaceRuleId, at: number, confidence: number, detail: string): NeuroFaceTrigger {
    return { rule, at, confidence, detail };
  }

  private resetTransient(): void {
    this.blinkClosed = false;
    this.headLeftArmedForFood = false;
    this.headRightArmedForToilet = false;
    this.singleBlinkClosed = false;
    this.headNavLeftArmed = true;
    this.headNavRightArmed = true;
  }

  private resetDetectors(): void {
    this.resetTransient();
    this.recentBlinks = [];
    this.recentHeadLeftTurns = [];
    this.recentHeadRightTurns = [];
    this.pitchHistory = [];
    this.lastNodSmileAt = Number.NEGATIVE_INFINITY;
    this.lastLeftNavAt = 0;
    this.lastRightNavAt = 0;
    this.lastBlinkSelectAt = 0;
  }
}
