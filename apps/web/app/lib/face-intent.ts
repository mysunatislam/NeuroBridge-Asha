/**
 * Patient-controlled face movement intents derived from MediaPipe FaceLandmarker
 * output. This module deliberately reports movements only. It must not be used
 * to infer emotion, pain, cognition, identity, or a medical condition.
 */

export const FACE_INTENT_IDS = ["blink", "eyes-left", "eyes-right", "brows-up", "mouth-open"] as const;

export type FaceIntentId = (typeof FACE_INTENT_IDS)[number];
export type FaceSignalSource = "none" | "blendshapes" | "landmarks" | "hybrid";
export type FaceIntentPhase =
  | "CALIBRATION_REQUIRED"
  | "NO_FACE"
  | "IDLE"
  | "DEBOUNCE"
  | "HOLD"
  | "COOLDOWN"
  | "WAIT_RELEASE";

export type FaceLandmarkLike = { x: number; y: number; z?: number; visibility?: number };
export type FaceBlendshapeCategoryLike = {
  score: number;
  index?: number;
  categoryName?: string;
  displayName?: string;
};

/** Structurally compatible with `FaceLandmarkerResult` from `@mediapipe/tasks-vision`. */
export type FaceLandmarkerCompatibleResult = {
  faceLandmarks?: ReadonlyArray<ReadonlyArray<FaceLandmarkLike>>;
  faceBlendshapes?: ReadonlyArray<{
    categories: ReadonlyArray<FaceBlendshapeCategoryLike>;
    headIndex?: number;
    headName?: string;
  }>;
};

export type FaceSignals = {
  facePresent: boolean;
  /** Bilateral eye closure, where larger values mean more closed. */
  blink: number | null;
  /** Patient-relative horizontal gaze: negative is left and positive is right. */
  gazeHorizontal: number | null;
  /** Brow-to-eye separation or the equivalent blendshape activation. */
  browsUp: number | null;
  /** Inner-lip opening or the equivalent blendshape activation. */
  mouthOpen: number | null;
  source: FaceSignalSource;
};

export type FaceSignalExtractionOptions = {
  faceIndex?: number;
  /** Flip when pixels were mirrored before inference. A CSS mirror needs no flip. */
  mirrorHorizontal?: boolean;
};

export type FaceMetricBaseline = { center: number; noise: number };
export type FaceNeutralBaseline = {
  version: 1;
  sampleCount: number;
  blink: FaceMetricBaseline;
  gazeHorizontal: FaceMetricBaseline;
  browsUp: FaceMetricBaseline;
  mouthOpen: FaceMetricBaseline;
};

export type FaceIntentRule = {
  enabled: boolean;
  minimumDelta: number;
  noiseMultiplier: number;
  debounceMs: number;
  holdMs: number;
  releaseRatio: number;
  cooldownMs: number;
};

export type FaceIntentRules = Record<FaceIntentId, FaceIntentRule>;
export type FaceIntentTrigger = { id: FaceIntentId; at: number; activationRatio: number };
export type FaceIntentOutput = {
  phase: FaceIntentPhase;
  candidateId: FaceIntentId | null;
  progress: number;
  trigger: FaceIntentTrigger | null;
  signals: FaceSignals;
  activationRatios: Record<FaceIntentId, number>;
};
export type FaceIntentEngineOptions = {
  extraction?: FaceSignalExtractionOptions;
  rules?: Partial<Record<FaceIntentId, Partial<FaceIntentRule>>>;
};

const NO_SIGNALS: FaceSignals = Object.freeze({
  facePresent: false,
  blink: null,
  gazeHorizontal: null,
  browsUp: null,
  mouthOpen: null,
  source: "none",
});

export const DEFAULT_FACE_INTENT_RULES: FaceIntentRules = Object.freeze({
  blink: Object.freeze({ enabled: true, minimumDelta: .32, noiseMultiplier: 4, debounceMs: 80, holdMs: 260, releaseRatio: .45, cooldownMs: 900 }),
  "eyes-left": Object.freeze({ enabled: true, minimumDelta: .22, noiseMultiplier: 4, debounceMs: 120, holdMs: 420, releaseRatio: .5, cooldownMs: 900 }),
  "eyes-right": Object.freeze({ enabled: true, minimumDelta: .22, noiseMultiplier: 4, debounceMs: 120, holdMs: 420, releaseRatio: .5, cooldownMs: 900 }),
  "brows-up": Object.freeze({ enabled: true, minimumDelta: .18, noiseMultiplier: 4, debounceMs: 120, holdMs: 420, releaseRatio: .5, cooldownMs: 900 }),
  "mouth-open": Object.freeze({ enabled: true, minimumDelta: .24, noiseMultiplier: 4, debounceMs: 120, holdMs: 420, releaseRatio: .5, cooldownMs: 900 }),
});

const LANDMARK = Object.freeze({
  leftEyeOuter: 33, leftEyeInner: 133,
  leftEyeUpperOuter: 160, leftEyeLowerOuter: 144,
  leftEyeUpperInner: 158, leftEyeLowerInner: 153,
  leftIrisCenter: 468,
  rightEyeInner: 362, rightEyeOuter: 263,
  rightEyeUpperInner: 385, rightEyeLowerInner: 380,
  rightEyeUpperOuter: 387, rightEyeLowerOuter: 373,
  rightIrisCenter: 473,
  leftBrowOuter: 70, leftBrowInner: 105,
  rightBrowInner: 334, rightBrowOuter: 300,
  upperLipInner: 13, lowerLipInner: 14,
  mouthLeft: 78, mouthRight: 308,
});

/** Extracts movement features without retaining a video frame or inferring an expression. */
export function extractFaceSignals(
  result: FaceLandmarkerCompatibleResult,
  options: FaceSignalExtractionOptions = {},
): FaceSignals {
  const faceIndex = normalizeFaceIndex(options.faceIndex);
  const categories = result.faceBlendshapes?.[faceIndex]?.categories ?? [];
  const landmarks = result.faceLandmarks?.[faceIndex] ?? [];
  const facePresent = categories.length > 0 || landmarks.length > 0;
  if (!facePresent) return { ...NO_SIGNALS };

  const scores = blendshapeScores(categories);
  const landmarkSignals = extractLandmarkSignals(landmarks, options.mirrorHorizontal ?? false);
  let blendshapeMetrics = 0;
  let landmarkMetrics = 0;
  const count = (source: "blendshape" | "landmark" | "none") => {
    blendshapeMetrics += source === "blendshape" ? 1 : 0;
    landmarkMetrics += source === "landmark" ? 1 : 0;
  };

  const blink = preferBlendshape(
    bilateralMinimum(scores.get("eyeBlinkLeft"), scores.get("eyeBlinkRight")),
    landmarkSignals.blink,
  );
  count(blink.source);

  const patientLeft = averagePresent(scores.get("eyeLookOutLeft"), scores.get("eyeLookInRight"));
  const patientRight = averagePresent(scores.get("eyeLookInLeft"), scores.get("eyeLookOutRight"));
  const blendshapeGaze = patientLeft === null || patientRight === null ? null : clamp(patientRight - patientLeft, -1, 1);
  const gaze = preferBlendshape(blendshapeGaze, landmarkSignals.gazeHorizontal);
  count(gaze.source);

  const brows = preferBlendshape(
    averagePresent(scores.get("browInnerUp"), scores.get("browOuterUpLeft"), scores.get("browOuterUpRight")),
    landmarkSignals.browsUp,
  );
  count(brows.source);
  const mouth = preferBlendshape(scores.get("jawOpen") ?? null, landmarkSignals.mouthOpen);
  count(mouth.source);

  return {
    facePresent,
    blink: blink.value,
    gazeHorizontal: gaze.value,
    browsUp: brows.value,
    mouthOpen: mouth.value,
    source: signalSource(blendshapeMetrics, landmarkMetrics),
  };
}

/** Builds a robust patient-specific neutral baseline from accepted neutral frames. */
export function buildNeutralFaceBaseline(
  samples: ReadonlyArray<FaceSignals>,
  minimumSamples = 15,
): FaceNeutralBaseline {
  if (!Number.isInteger(minimumSamples) || minimumSamples < 1) throw new Error("minimumSamples must be a positive integer.");
  const complete = samples.filter(hasCompleteSignals);
  if (complete.length < minimumSamples) {
    throw new Error(`Neutral calibration needs at least ${minimumSamples} complete face samples; received ${complete.length}.`);
  }
  return {
    version: 1,
    sampleCount: complete.length,
    blink: robustMetric(complete.map((sample) => sample.blink as number)),
    gazeHorizontal: robustMetric(complete.map((sample) => sample.gazeHorizontal as number)),
    browsUp: robustMetric(complete.map((sample) => sample.browsUp as number)),
    mouthOpen: robustMetric(complete.map((sample) => sample.mouthOpen as number)),
  };
}

export class NeutralFaceCalibrator {
  private readonly samples: FaceSignals[] = [];

  constructor(
    readonly minimumSamples = 30,
    private readonly maximumSamples = 180,
    private readonly extraction: FaceSignalExtractionOptions = {},
  ) {
    if (!Number.isInteger(minimumSamples) || minimumSamples < 1) throw new Error("minimumSamples must be a positive integer.");
    if (!Number.isInteger(maximumSamples) || maximumSamples < minimumSamples) {
      throw new Error("maximumSamples must be an integer no smaller than minimumSamples.");
    }
  }

  add(input: FaceLandmarkerCompatibleResult | FaceSignals): boolean {
    const faceSignals = isFaceSignals(input) ? sanitizeSignals(input) : extractFaceSignals(input, this.extraction);
    if (!hasCompleteSignals(faceSignals)) return false;
    if (this.samples.length === this.maximumSamples) this.samples.shift();
    this.samples.push({ ...faceSignals });
    return true;
  }

  get acceptedSamples(): number {
    return this.samples.length;
  }

  get progress(): number {
    return Math.min(1, this.samples.length / this.minimumSamples);
  }

  get ready(): boolean {
    return this.samples.length >= this.minimumSamples;
  }

  finish(): FaceNeutralBaseline {
    return buildNeutralFaceBaseline(this.samples, this.minimumSamples);
  }

  reset(): void {
    this.samples.length = 0;
  }
}

/**
 * Converts calibrated movements into deliberate one-shot intents. The caller
 * owns phrase selection, text-to-speech, and any caregiver action.
 */
export class FaceIntentEngine {
  private baseline: FaceNeutralBaseline | null;
  private readonly rules: FaceIntentRules;
  private readonly extraction: FaceSignalExtractionOptions;
  private candidateId: FaceIntentId | null = null;
  private candidateSince = 0;
  private lockedIntent: FaceIntentId | null = null;
  private releaseObserved = false;
  private cooldownUntil = 0;
  private lastNow = Number.NEGATIVE_INFINITY;
  private lastOutput: FaceIntentOutput;

  constructor(baseline: FaceNeutralBaseline | null = null, options: FaceIntentEngineOptions = {}) {
    this.baseline = baseline ? validateBaseline(baseline) : null;
    this.rules = mergeRules(options.rules);
    this.extraction = { ...options.extraction };
    this.lastOutput = this.output(this.baseline ? "IDLE" : "CALIBRATION_REQUIRED", null, 0, null, { ...NO_SIGNALS }, emptyRatios());
  }

  setBaseline(baseline: FaceNeutralBaseline): void {
    this.baseline = validateBaseline(baseline);
    this.resetState();
  }

  clearBaseline(): void {
    this.baseline = null;
    this.resetState();
  }

  step(input: FaceLandmarkerCompatibleResult | FaceSignals, now: number): FaceIntentOutput {
    if (!Number.isFinite(now)) throw new Error("Face intent timestamps must be finite.");
    const effectiveNow = Math.max(now, this.lastNow);
    this.lastNow = effectiveNow;
    const faceSignals = isFaceSignals(input) ? sanitizeSignals(input) : extractFaceSignals(input, this.extraction);
    const ratios = this.baseline ? activationRatios(faceSignals, this.baseline, this.rules) : emptyRatios();

    if (!this.baseline) {
      this.clearCandidate();
      return this.remember(this.output("CALIBRATION_REQUIRED", null, 0, null, faceSignals, ratios));
    }
    if (!faceSignals.facePresent) {
      this.clearCandidate();
      return this.remember(this.output("NO_FACE", null, 0, null, faceSignals, ratios));
    }

    if (this.lockedIntent) {
      const lockedRule = this.rules[this.lockedIntent];
      if (ratios[this.lockedIntent] <= lockedRule.releaseRatio) this.releaseObserved = true;
      if (effectiveNow < this.cooldownUntil) {
        return this.remember(this.output("COOLDOWN", null, cooldownProgress(effectiveNow, this.cooldownUntil, lockedRule.cooldownMs), null, faceSignals, ratios));
      }
      if (!this.releaseObserved) return this.remember(this.output("WAIT_RELEASE", null, 1, null, faceSignals, ratios));
      this.lockedIntent = null;
      this.releaseObserved = false;
      return this.remember(this.output("IDLE", null, 0, null, faceSignals, ratios));
    }

    if (this.candidateId && ratios[this.candidateId] < this.rules[this.candidateId].releaseRatio) this.clearCandidate();
    if (!this.candidateId) {
      const nextCandidate = strongestActiveIntent(ratios, this.rules);
      if (!nextCandidate) return this.remember(this.output("IDLE", null, 0, null, faceSignals, ratios));
      this.candidateId = nextCandidate;
      this.candidateSince = effectiveNow;
    }

    const candidate = this.candidateId;
    const rule = this.rules[candidate];
    const elapsed = Math.max(0, effectiveNow - this.candidateSince);
    if (elapsed < rule.debounceMs) {
      return this.remember(this.output("DEBOUNCE", candidate, divideProgress(elapsed, rule.debounceMs), null, faceSignals, ratios));
    }
    const holdElapsed = elapsed - rule.debounceMs;
    if (holdElapsed < rule.holdMs) {
      return this.remember(this.output("HOLD", candidate, divideProgress(holdElapsed, rule.holdMs), null, faceSignals, ratios));
    }

    const trigger: FaceIntentTrigger = { id: candidate, at: effectiveNow, activationRatio: ratios[candidate] };
    this.lockedIntent = candidate;
    this.releaseObserved = false;
    this.cooldownUntil = effectiveNow + rule.cooldownMs;
    this.clearCandidate();
    return this.remember(this.output("COOLDOWN", null, 0, trigger, faceSignals, ratios));
  }

  snapshot(): FaceIntentOutput {
    return {
      ...this.lastOutput,
      signals: { ...this.lastOutput.signals },
      activationRatios: { ...this.lastOutput.activationRatios },
      trigger: this.lastOutput.trigger ? { ...this.lastOutput.trigger } : null,
    };
  }

  private clearCandidate(): void {
    this.candidateId = null;
    this.candidateSince = 0;
  }

  private resetState(): void {
    this.clearCandidate();
    this.lockedIntent = null;
    this.releaseObserved = false;
    this.cooldownUntil = 0;
    this.lastNow = Number.NEGATIVE_INFINITY;
    this.lastOutput = this.output(this.baseline ? "IDLE" : "CALIBRATION_REQUIRED", null, 0, null, { ...NO_SIGNALS }, emptyRatios());
  }

  private output(
    phase: FaceIntentPhase,
    candidateId: FaceIntentId | null,
    progress: number,
    trigger: FaceIntentTrigger | null,
    signals: FaceSignals,
    ratios: Record<FaceIntentId, number>,
  ): FaceIntentOutput {
    return { phase, candidateId, progress: clamp(progress, 0, 1), trigger, signals, activationRatios: ratios };
  }

  private remember(output: FaceIntentOutput): FaceIntentOutput {
    this.lastOutput = output;
    return output;
  }
}

function extractLandmarkSignals(
  landmarks: ReadonlyArray<FaceLandmarkLike>,
  mirrorHorizontal: boolean,
): Omit<FaceSignals, "facePresent" | "source"> {
  if (!hasLandmarks(landmarks, Object.values(LANDMARK))) {
    return { blink: null, gazeHorizontal: null, browsUp: null, mouthOpen: null };
  }

  const leftEyeWidth = distance(landmarks[LANDMARK.leftEyeOuter], landmarks[LANDMARK.leftEyeInner]);
  const rightEyeWidth = distance(landmarks[LANDMARK.rightEyeInner], landmarks[LANDMARK.rightEyeOuter]);
  const leftEar = eyeAspectRatio(
    landmarks[LANDMARK.leftEyeOuter], landmarks[LANDMARK.leftEyeInner],
    landmarks[LANDMARK.leftEyeUpperOuter], landmarks[LANDMARK.leftEyeLowerOuter],
    landmarks[LANDMARK.leftEyeUpperInner], landmarks[LANDMARK.leftEyeLowerInner],
  );
  const rightEar = eyeAspectRatio(
    landmarks[LANDMARK.rightEyeInner], landmarks[LANDMARK.rightEyeOuter],
    landmarks[LANDMARK.rightEyeUpperInner], landmarks[LANDMARK.rightEyeLowerInner],
    landmarks[LANDMARK.rightEyeUpperOuter], landmarks[LANDMARK.rightEyeLowerOuter],
  );
  const blink = leftEar === null || rightEar === null ? null : clamp(1 - Math.min(leftEar, rightEar) / .3, 0, 1);

  const leftIrisRatio = horizontalRatio(landmarks[LANDMARK.leftIrisCenter], landmarks[LANDMARK.leftEyeOuter], landmarks[LANDMARK.leftEyeInner]);
  const rightIrisRatio = horizontalRatio(landmarks[LANDMARK.rightIrisCenter], landmarks[LANDMARK.rightEyeInner], landmarks[LANDMARK.rightEyeOuter]);
  const irisRatio = leftIrisRatio === null || rightIrisRatio === null ? null : (leftIrisRatio + rightIrisRatio) / 2;
  let gazeHorizontal = irisRatio === null ? null : clamp((.5 - irisRatio) * 2, -1, 1);
  if (gazeHorizontal !== null && mirrorHorizontal) gazeHorizontal *= -1;

  const faceWidth = distance(landmarks[LANDMARK.leftEyeOuter], landmarks[LANDMARK.rightEyeOuter]);
  const browDistances = [
    distance(landmarks[LANDMARK.leftBrowOuter], landmarks[LANDMARK.leftEyeUpperOuter]),
    distance(landmarks[LANDMARK.leftBrowInner], landmarks[LANDMARK.leftEyeUpperInner]),
    distance(landmarks[LANDMARK.rightBrowInner], landmarks[LANDMARK.rightEyeUpperInner]),
    distance(landmarks[LANDMARK.rightBrowOuter], landmarks[LANDMARK.rightEyeUpperOuter]),
  ];
  const browsUp = faceWidth > 1e-6 ? average(browDistances) / faceWidth : null;
  const mouthWidth = distance(landmarks[LANDMARK.mouthLeft], landmarks[LANDMARK.mouthRight]);
  const mouthOpen = mouthWidth > 1e-6 ? distance(landmarks[LANDMARK.upperLipInner], landmarks[LANDMARK.lowerLipInner]) / mouthWidth : null;
  const validEyes = leftEyeWidth > 1e-6 && rightEyeWidth > 1e-6;
  return {
    blink: validEyes ? finiteOrNull(blink) : null,
    gazeHorizontal: validEyes ? finiteOrNull(gazeHorizontal) : null,
    browsUp: finiteOrNull(browsUp),
    mouthOpen: finiteOrNull(mouthOpen),
  };
}

function activationRatios(
  signals: FaceSignals,
  baseline: FaceNeutralBaseline,
  rules: FaceIntentRules,
): Record<FaceIntentId, number> {
  if (!signals.facePresent) return emptyRatios();
  return {
    blink: thresholdRatio(positiveDelta(signals.blink, baseline.blink.center), baseline.blink, rules.blink),
    "eyes-left": thresholdRatio(negativeDelta(signals.gazeHorizontal, baseline.gazeHorizontal.center), baseline.gazeHorizontal, rules["eyes-left"]),
    "eyes-right": thresholdRatio(positiveDelta(signals.gazeHorizontal, baseline.gazeHorizontal.center), baseline.gazeHorizontal, rules["eyes-right"]),
    "brows-up": thresholdRatio(positiveDelta(signals.browsUp, baseline.browsUp.center), baseline.browsUp, rules["brows-up"]),
    "mouth-open": thresholdRatio(positiveDelta(signals.mouthOpen, baseline.mouthOpen.center), baseline.mouthOpen, rules["mouth-open"]),
  };
}

function thresholdRatio(delta: number | null, baseline: FaceMetricBaseline, rule: FaceIntentRule): number {
  if (delta === null || !rule.enabled) return 0;
  const threshold = Math.max(rule.minimumDelta, baseline.noise * rule.noiseMultiplier, 1e-6);
  return Math.max(0, delta / threshold);
}

function strongestActiveIntent(
  ratios: Record<FaceIntentId, number>,
  rules: FaceIntentRules,
): FaceIntentId | null {
  let strongest: FaceIntentId | null = null;
  for (const id of FACE_INTENT_IDS) {
    if (!rules[id].enabled || ratios[id] < 1) continue;
    if (!strongest || ratios[id] > ratios[strongest]) strongest = id;
  }
  return strongest;
}

function robustMetric(values: ReadonlyArray<number>): FaceMetricBaseline {
  const center = median(values);
  const absoluteDeviations = values.map((value) => Math.abs(value - center));
  return { center, noise: Math.max(1.4826 * median(absoluteDeviations), 1e-4) };
}

function median(values: ReadonlyArray<number>): number {
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle];
}

function validateBaseline(value: FaceNeutralBaseline): FaceNeutralBaseline {
  if (value.version !== 1 || !Number.isInteger(value.sampleCount) || value.sampleCount < 1) {
    throw new Error("Face neutral baseline is invalid.");
  }
  for (const metric of [value.blink, value.gazeHorizontal, value.browsUp, value.mouthOpen]) {
    if (!Number.isFinite(metric.center) || !Number.isFinite(metric.noise) || metric.noise < 0) {
      throw new Error("Face neutral baseline contains an invalid metric.");
    }
  }
  return structuredClone(value);
}

function mergeRules(overrides: FaceIntentEngineOptions["rules"]): FaceIntentRules {
  const entries = FACE_INTENT_IDS.map((id) => {
    const rule = { ...DEFAULT_FACE_INTENT_RULES[id], ...overrides?.[id] };
    validateRule(id, rule);
    return [id, rule] as const;
  });
  return Object.fromEntries(entries) as FaceIntentRules;
}

function validateRule(id: FaceIntentId, rule: FaceIntentRule): void {
  for (const key of ["minimumDelta", "noiseMultiplier", "debounceMs", "holdMs", "cooldownMs"] as const) {
    if (!Number.isFinite(rule[key]) || rule[key] < 0) throw new Error(`${id} ${key} must be a non-negative finite number.`);
  }
  if (!Number.isFinite(rule.releaseRatio) || rule.releaseRatio < 0 || rule.releaseRatio >= 1) {
    throw new Error(`${id} releaseRatio must be at least 0 and below 1.`);
  }
}

function sanitizeSignals(signals: FaceSignals): FaceSignals {
  return {
    facePresent: signals.facePresent === true,
    blink: finiteOrNull(signals.blink),
    gazeHorizontal: finiteOrNull(signals.gazeHorizontal),
    browsUp: finiteOrNull(signals.browsUp),
    mouthOpen: finiteOrNull(signals.mouthOpen),
    source: signals.source,
  };
}

function hasCompleteSignals(signals: FaceSignals): boolean {
  return signals.facePresent && [signals.blink, signals.gazeHorizontal, signals.browsUp, signals.mouthOpen]
    .every((value) => value !== null && Number.isFinite(value));
}

function isFaceSignals(input: FaceLandmarkerCompatibleResult | FaceSignals): input is FaceSignals {
  return "facePresent" in input;
}

function blendshapeScores(categories: ReadonlyArray<FaceBlendshapeCategoryLike>): Map<string, number> {
  const scores = new Map<string, number>();
  for (const category of categories) {
    const name = category.categoryName;
    if (!name || !Number.isFinite(category.score)) continue;
    const score = clamp(category.score, 0, 1);
    scores.set(name, Math.max(scores.get(name) ?? 0, score));
  }
  return scores;
}

function preferBlendshape(
  blendshape: number | null,
  landmark: number | null,
): { value: number | null; source: "blendshape" | "landmark" | "none" } {
  if (blendshape !== null && Number.isFinite(blendshape)) return { value: blendshape, source: "blendshape" };
  if (landmark !== null && Number.isFinite(landmark)) return { value: landmark, source: "landmark" };
  return { value: null, source: "none" };
}

function signalSource(blendshapeMetrics: number, landmarkMetrics: number): FaceSignalSource {
  if (blendshapeMetrics > 0 && landmarkMetrics > 0) return "hybrid";
  if (blendshapeMetrics > 0) return "blendshapes";
  if (landmarkMetrics > 0) return "landmarks";
  return "none";
}

function bilateralMinimum(left: number | undefined, right: number | undefined): number | null {
  return left === undefined || right === undefined ? null : Math.min(left, right);
}

function averagePresent(...values: Array<number | undefined>): number | null {
  const present = values.filter((value): value is number => value !== undefined && Number.isFinite(value));
  return present.length > 0 ? average(present) : null;
}

function average(values: ReadonlyArray<number>): number {
  return values.reduce((total, value) => total + value, 0) / values.length;
}

function eyeAspectRatio(
  outer: FaceLandmarkLike,
  inner: FaceLandmarkLike,
  upperOuter: FaceLandmarkLike,
  lowerOuter: FaceLandmarkLike,
  upperInner: FaceLandmarkLike,
  lowerInner: FaceLandmarkLike,
): number | null {
  const width = distance(outer, inner);
  return width > 1e-6
    ? (distance(upperOuter, lowerOuter) + distance(upperInner, lowerInner)) / (2 * width)
    : null;
}

function horizontalRatio(
  point: FaceLandmarkLike,
  firstCorner: FaceLandmarkLike,
  secondCorner: FaceLandmarkLike,
): number | null {
  const minimum = Math.min(firstCorner.x, secondCorner.x);
  const width = Math.abs(firstCorner.x - secondCorner.x);
  return width > 1e-6 ? clamp((point.x - minimum) / width, 0, 1) : null;
}

function distance(first: FaceLandmarkLike, second: FaceLandmarkLike): number {
  return Math.hypot(first.x - second.x, first.y - second.y);
}

function hasLandmarks(landmarks: ReadonlyArray<FaceLandmarkLike>, indexes: ReadonlyArray<number>): boolean {
  return indexes.every((index) => {
    const landmark = landmarks[index];
    return landmark !== undefined && Number.isFinite(landmark.x) && Number.isFinite(landmark.y);
  });
}

function positiveDelta(value: number | null, center: number): number | null {
  return value === null ? null : Math.max(0, value - center);
}

function negativeDelta(value: number | null, center: number): number | null {
  return value === null ? null : Math.max(0, center - value);
}

function finiteOrNull(value: number | null): number | null {
  return value !== null && Number.isFinite(value) ? value : null;
}

function emptyRatios(): Record<FaceIntentId, number> {
  return { blink: 0, "eyes-left": 0, "eyes-right": 0, "brows-up": 0, "mouth-open": 0 };
}

function cooldownProgress(now: number, cooldownUntil: number, cooldownMs: number): number {
  return cooldownMs === 0 ? 1 : 1 - Math.max(0, cooldownUntil - now) / cooldownMs;
}

function divideProgress(elapsed: number, duration: number): number {
  return duration === 0 ? 1 : elapsed / duration;
}

function normalizeFaceIndex(value: number | undefined): number {
  if (value === undefined) return 0;
  if (!Number.isInteger(value) || value < 0) throw new Error("faceIndex must be a non-negative integer.");
  return value;
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(maximum, Math.max(minimum, value));
}
