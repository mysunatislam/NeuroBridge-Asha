export const SEQUENCE_LENGTH = 20;
export const RAW_FRAME_LENGTH = 63;
export const STATIC_FEATURE_LENGTH = 83;
export const FEATURE_LENGTH = 98;
export const PROFILE_VERSION = 3;
export const OOD_REJECT_MULTIPLIER = 2.2;
export const CONFIDENCE_THRESHOLD = 0.72;

const SAFE_IDENTIFIER = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$/;

const FINGERTIP_INDICES = [4, 8, 12, 16, 20] as const;
const FINGER_CHAINS = [
  [1, 2, 3, 4],
  [5, 6, 7, 8],
  [9, 10, 11, 12],
  [13, 14, 15, 16],
  [17, 18, 19, 20],
] as const;

export type RiskLevel = "routine" | "clinical" | "emergency";
export type TimedRawFrame = { t: number; raw: number[] };
export type GestureSample = { raw: number[][]; session: string; capturedAt?: string };
export type Gesture = {
  id: string;
  name: string;
  phrase: string;
  icon: string;
  protected?: boolean;
  risk: RiskLevel;
  dwellMs: number;
  samples: GestureSample[];
};
export type FingerSpeakProfile = {
  version: typeof PROFILE_VERSION;
  id: string;
  name: string;
  consentToEventSync: boolean;
  consentToCaregiverAlerts: boolean;
  consentToLandmarkSync: boolean;
  gestures: Gesture[];
  updatedAt: string;
};
export type ClassPrototype = { gestureId: string; centroid: number[]; spread: number };
export type PrototypeModel = {
  featureVersion: "3d-angle-motion-v1";
  sequenceLength: typeof SEQUENCE_LENGTH;
  featureLength: typeof FEATURE_LENGTH;
  profileFingerprint: string;
  prototypes: ClassPrototype[];
  trainedAt: string;
};
export type Prediction = {
  gestureId: string | null;
  confidence: number;
  inDistribution: boolean;
  distances: Record<string, number>;
};

export const DEFAULT_GESTURES: Gesture[] = [
  { id: "rest", name: "Rest", phrase: "", icon: "✋", protected: true, risk: "routine", dwellMs: 500, samples: [] },
  { id: "yes", name: "Yes", phrase: "Yes.", icon: "👍", risk: "routine", dwellMs: 650, samples: [] },
  { id: "no", name: "No", phrase: "No.", icon: "↔", risk: "routine", dwellMs: 650, samples: [] },
  { id: "water", name: "Water", phrase: "I need water, please.", icon: "💧", risk: "routine", dwellMs: 750, samples: [] },
  { id: "nurse", name: "Nurse", phrase: "Please call the nurse.", icon: "●", risk: "clinical", dwellMs: 1_000, samples: [] },
  { id: "emergency", name: "Emergency", phrase: "This is an emergency. I need help now.", icon: "!", risk: "emergency", dwellMs: 1_500, samples: [] },
];

export function createDefaultProfile(): FingerSpeakProfile {
  return {
    version: PROFILE_VERSION,
    id: "local-profile",
    name: "My communication profile",
    consentToEventSync: false,
    consentToCaregiverAlerts: false,
    consentToLandmarkSync: false,
    gestures: structuredClone(DEFAULT_GESTURES),
    updatedAt: new Date().toISOString(),
  };
}

type Vec3 = [number, number, number];

function norm(vector: Vec3): Vec3 {
  const length = Math.hypot(...vector) || 1e-6;
  return vector.map((value) => value / length) as Vec3;
}
function dot(a: Vec3, b: Vec3): number { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
function cross(a: Vec3, b: Vec3): Vec3 {
  return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
}
function subtract(a: Vec3, b: Vec3): Vec3 { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
function scale(vector: Vec3, amount: number): Vec3 { return vector.map((value) => value * amount) as Vec3; }

export function flattenLandmarks(landmarks: ReadonlyArray<{ x: number; y: number; z?: number }>): number[] {
  if (landmarks.length !== 21) throw new Error("A hand frame must contain exactly 21 landmarks.");
  return landmarks.flatMap((landmark) => [landmark.x, landmark.y, landmark.z ?? 0]);
}

export function computeFrameFeatures(raw: ReadonlyArray<number>): number[] {
  assertFiniteVector(raw, RAW_FRAME_LENGTH, "raw landmark frame");
  const point = (index: number): Vec3 => [raw[index * 3], raw[index * 3 + 1], raw[index * 3 + 2]];
  const wrist = point(0);
  const middleMcp = point(9);
  const indexMcp = point(5);
  const pinkyMcp = point(17);
  const scaleLength = Math.hypot(...subtract(middleMcp, wrist)) || 1e-6;
  const yAxis = norm(subtract(middleMcp, wrist));
  const horizontal = subtract(pinkyMcp, indexMcp);
  const projection = dot(horizontal, yAxis);
  const xAxis = norm([
    horizontal[0] - projection * yAxis[0],
    horizontal[1] - projection * yAxis[1],
    horizontal[2] - projection * yAxis[2],
  ]);
  const zAxis = norm(cross(xAxis, yAxis));

  const coordinates: number[] = [];
  for (let index = 0; index < 21; index += 1) {
    const relative = scale(subtract(point(index), wrist), 1 / scaleLength);
    coordinates.push(dot(relative, xAxis), dot(relative, yAxis), dot(relative, zAxis));
  }
  const angles: number[] = [];
  for (const chain of FINGER_CHAINS) {
    for (let index = 0; index < chain.length - 2; index += 1) {
      const a = point(chain[index]);
      const b = point(chain[index + 1]);
      const c = point(chain[index + 2]);
      const cosine = Math.max(-1, Math.min(1, dot(norm(subtract(a, b)), norm(subtract(c, b)))));
      angles.push(Math.acos(cosine) / Math.PI);
    }
  }
  const distances: number[] = [];
  for (let left = 0; left < FINGERTIP_INDICES.length; left += 1) {
    for (let right = left + 1; right < FINGERTIP_INDICES.length; right += 1) {
      distances.push(Math.hypot(...subtract(point(FINGERTIP_INDICES[left]), point(FINGERTIP_INDICES[right]))) / scaleLength);
    }
  }
  const features = [...coordinates, ...angles, ...distances];
  assertFiniteVector(features, STATIC_FEATURE_LENGTH, "engineered feature frame");
  return features;
}

export function addVelocity(sequence: ReadonlyArray<ReadonlyArray<number>>): number[][] {
  return sequence.map((frame, frameIndex) => {
    assertFiniteVector(frame, STATIC_FEATURE_LENGTH, "static feature frame");
    const previous = frameIndex > 0 ? sequence[frameIndex - 1] : frame;
    const velocity: number[] = [];
    for (const fingertipIndex of FINGERTIP_INDICES) {
      const coordinate = fingertipIndex * 3;
      velocity.push(frame[coordinate] - previous[coordinate], frame[coordinate + 1] - previous[coordinate + 1], frame[coordinate + 2] - previous[coordinate + 2]);
    }
    return [...frame, ...velocity];
  });
}

export function buildModelInput(rawSequence: ReadonlyArray<ReadonlyArray<number>>): number[][] {
  if (rawSequence.length !== SEQUENCE_LENGTH) throw new Error(`A model sequence must contain ${SEQUENCE_LENGTH} frames.`);
  const result = addVelocity(rawSequence.map(computeFrameFeatures));
  result.forEach((frame) => assertFiniteVector(frame, FEATURE_LENGTH, "model feature frame"));
  return result;
}

export function resampleSequence(timedFrames: ReadonlyArray<TimedRawFrame>, count = SEQUENCE_LENGTH, windowMs = 900): number[][] | null {
  if (timedFrames.length < 2) return null;
  timedFrames.forEach((frame) => assertFiniteVector(frame.raw, RAW_FRAME_LENGTH, "timed raw frame"));
  const latest = timedFrames.at(-1)!.t;
  const start = latest - windowMs;
  const frames = timedFrames.filter((frame) => frame.t >= start - 50);
  if (frames.length < 2) return null;
  return Array.from({ length: count }, (_, index) => {
    const target = start + (index / Math.max(1, count - 1)) * windowMs;
    let lower = frames[0];
    let upper = frames.at(-1)!;
    for (let cursor = 0; cursor < frames.length - 1; cursor += 1) {
      if (frames[cursor].t <= target && frames[cursor + 1].t >= target) {
        lower = frames[cursor];
        upper = frames[cursor + 1];
        break;
      }
    }
    const duration = upper.t - lower.t;
    const alpha = duration > 0 ? Math.max(0, Math.min(1, (target - lower.t) / duration)) : 0;
    return lower.raw.map((value, coordinate) => value + (upper.raw[coordinate] - value) * alpha);
  });
}

export function summaryVector(sequence: ReadonlyArray<ReadonlyArray<number>>): number[] {
  if (!sequence.length) throw new Error("Cannot summarize an empty sequence.");
  const dimensions = sequence[0].length;
  sequence.forEach((frame) => assertFiniteVector(frame, dimensions, "feature sequence"));
  const mean = new Array(dimensions).fill(0);
  for (const frame of sequence) for (let dimension = 0; dimension < dimensions; dimension += 1) mean[dimension] += frame[dimension] / sequence.length;
  const deviation = new Array(dimensions).fill(0);
  for (const frame of sequence) for (let dimension = 0; dimension < dimensions; dimension += 1) deviation[dimension] += (frame[dimension] - mean[dimension]) ** 2 / sequence.length;
  return mean.concat(deviation.map(Math.sqrt));
}

export function euclideanDistance(a: ReadonlyArray<number>, b: ReadonlyArray<number>): number {
  assertFiniteVector(b, a.length, "distance vector");
  return Math.sqrt(a.reduce((sum, value, index) => sum + (value - b[index]) ** 2, 0));
}

export function dtwDistance(sequenceA: ReadonlyArray<ReadonlyArray<number>>, sequenceB: ReadonlyArray<ReadonlyArray<number>>): number {
  if (!sequenceA.length || !sequenceB.length) return Number.POSITIVE_INFINITY;
  let previous = new Array(sequenceB.length + 1).fill(Number.POSITIVE_INFINITY);
  let current = new Array(sequenceB.length + 1).fill(Number.POSITIVE_INFINITY);
  previous[0] = 0;
  for (let aIndex = 1; aIndex <= sequenceA.length; aIndex += 1) {
    current[0] = Number.POSITIVE_INFINITY;
    for (let bIndex = 1; bIndex <= sequenceB.length; bIndex += 1) {
      const cost = euclideanDistance(sequenceA[aIndex - 1], sequenceB[bIndex - 1]);
      current[bIndex] = cost + Math.min(previous[bIndex], current[bIndex - 1], previous[bIndex - 1]);
    }
    [previous, current] = [current, previous];
  }
  return previous[sequenceB.length];
}

export function trainPrototypeModel(gestures: ReadonlyArray<Gesture>, profileFingerprint: string): PrototypeModel {
  const prototypes = gestures.map((gesture) => {
    if (!gesture.samples.length) throw new Error(`${gesture.name} needs at least one calibration sample.`);
    const summaries = gesture.samples.map((sample) => summaryVector(buildModelInput(sample.raw)));
    const centroid = new Array(summaries[0].length).fill(0);
    for (const summary of summaries) for (let index = 0; index < summary.length; index += 1) centroid[index] += summary[index] / summaries.length;
    const spread = summaries.reduce((total, summary) => total + euclideanDistance(summary, centroid), 0) / summaries.length;
    return { gestureId: gesture.id, centroid, spread: Math.max(spread, 0.05) };
  });
  return { featureVersion: "3d-angle-motion-v1", sequenceLength: SEQUENCE_LENGTH, featureLength: FEATURE_LENGTH, profileFingerprint, prototypes, trainedAt: new Date().toISOString() };
}

export async function profileModelFingerprint(profile: FingerSpeakProfile): Promise<string> {
  const encoder = new TextEncoder();
  const magic = encoder.encode("fingerspeak-profile-binding-v1\0");
  const encodedGestures = profile.gestures.map((gesture) => ({
    gesture,
    strings: [gesture.id, gesture.name, gesture.phrase, gesture.risk].map((value) => encoder.encode(value)),
    sessions: gesture.samples.map((sample) => encoder.encode(sample.session)),
  }));
  let byteLength = magic.byteLength + 4;
  for (const { gesture, strings, sessions } of encodedGestures) {
    byteLength += strings.reduce((total, value) => total + 4 + value.byteLength, 0) + 8;
    for (let sampleIndex = 0; sampleIndex < gesture.samples.length; sampleIndex += 1) {
      const sample = gesture.samples[sampleIndex];
      if (sample.raw.length !== SEQUENCE_LENGTH) throw new Error("A calibration sample must contain exactly 20 frames.");
      sample.raw.forEach((frame) => assertFiniteVector(frame, RAW_FRAME_LENGTH, "calibration frame"));
      byteLength += 4 + sessions[sampleIndex].byteLength + SEQUENCE_LENGTH * RAW_FRAME_LENGTH * 8;
    }
  }
  const bytes = new Uint8Array(byteLength);
  const view = new DataView(bytes.buffer);
  let offset = 0;
  const writeBytes = (value: Uint8Array) => { bytes.set(value, offset); offset += value.byteLength; };
  const writeUint32 = (value: number) => { view.setUint32(offset, value, true); offset += 4; };
  const writeString = (value: Uint8Array) => { writeUint32(value.byteLength); writeBytes(value); };
  writeBytes(magic);
  writeUint32(encodedGestures.length);
  for (const { gesture, strings, sessions } of encodedGestures) {
    strings.forEach(writeString);
    writeUint32(gesture.dwellMs);
    writeUint32(gesture.samples.length);
    gesture.samples.forEach((sample, sampleIndex) => {
      writeString(sessions[sampleIndex]);
      sample.raw.forEach((frame) => frame.forEach((coordinate) => {
        view.setFloat64(offset, coordinate, true);
        offset += 8;
      }));
    });
  }
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function predictPrototype(model: PrototypeModel, rawSequence: number[][]): Prediction {
  const summary = summaryVector(buildModelInput(rawSequence));
  const distances = Object.fromEntries(model.prototypes.map((prototype) => [prototype.gestureId, euclideanDistance(summary, prototype.centroid)]));
  const nearest = model.prototypes.reduce((best, current) => distances[current.gestureId] < distances[best.gestureId] ? current : best);
  const normalizedDistance = distances[nearest.gestureId] / Math.max(nearest.spread, 0.05);
  return {
    gestureId: nearest.gestureId,
    confidence: 1 / (1 + normalizedDistance),
    inDistribution: distances[nearest.gestureId] <= nearest.spread * OOD_REJECT_MULTIPLIER,
    distances,
  };
}

export function parseProfile(value: unknown, options: { preserveLocalConsent?: boolean } = {}): FingerSpeakProfile {
  if (!isRecord(value)) throw new Error("Profile must be a JSON object.");
  if (value.version !== 2 && value.version !== PROFILE_VERSION) throw new Error("Unsupported FingerSpeak profile version.");
  const strict = value.version === PROFILE_VERSION;
  if (strict) {
    assertOnlyKeys(value, ["version", "id", "name", "consentToEventSync", "consentToCaregiverAlerts", "consentToLandmarkSync", "gestures", "updatedAt"], "Profile");
    if (typeof value.consentToEventSync !== "undefined" && typeof value.consentToEventSync !== "boolean") throw new Error("consentToEventSync must be boolean.");
    if (typeof value.consentToCaregiverAlerts !== "undefined" && typeof value.consentToCaregiverAlerts !== "boolean") throw new Error("consentToCaregiverAlerts must be boolean.");
    if (typeof value.consentToLandmarkSync !== "undefined" && value.consentToLandmarkSync !== false) throw new Error("Landmark sync is not supported.");
  }
  if (!Array.isArray(value.gestures) || value.gestures.length < 2 || value.gestures.length > 24) throw new Error("A profile must contain between 2 and 24 gestures.");
  const gestures = value.gestures.map((gesture, index) => parseGesture(gesture, index, strict));
  if (strict) {
    const rests = gestures.filter((gesture) => gesture.id === "rest");
    if (rests.length !== 1 || rests[0].name !== "Rest" || rests[0].phrase !== "" || rests[0].protected !== true) throw new Error("Version 3 requires exactly one protected Rest gesture with id 'rest' and no phrase.");
  } else {
    const rests = gestures.filter((gesture) => gesture.id === "rest" || gesture.name.toLowerCase() === "rest");
    if (rests.length !== 1) throw new Error("A profile must contain exactly one Rest gesture.");
    Object.assign(rests[0], { id: "rest", name: "Rest", phrase: "", protected: true });
  }
  const gestureIds = gestures.map((gesture) => gesture.id);
  if (new Set(gestureIds).size !== gestureIds.length) throw new Error("Gesture IDs must be unique.");
  const gestureNames = gestures.map((gesture) => gesture.name.toLocaleLowerCase("en-US"));
  if (new Set(gestureNames).size !== gestureNames.length) throw new Error("Gesture names must be unique.");
  const name = strict ? cleanText(value.name, 80, "profile name") : typeof value.name === "string" ? cleanText(value.name, 80, "profile name") : "Imported profile";
  const id = strict
    ? requireIdentifier(value.id, "profile id")
    : typeof value.id === "string" && SAFE_IDENTIFIER.test(value.id) ? value.id : crypto.randomUUID();
  const updatedAt = strict ? requireDateTime(value.updatedAt, "updatedAt") : new Date().toISOString();
  return {
    version: PROFILE_VERSION,
    id,
    name,
    // Consent is device/user specific and never transfers through imported files.
    consentToEventSync: options.preserveLocalConsent === true && value.consentToEventSync === true,
    consentToCaregiverAlerts: options.preserveLocalConsent === true && value.consentToCaregiverAlerts === true,
    consentToLandmarkSync: false,
    gestures,
    updatedAt,
  };
}

function parseGesture(value: unknown, index: number, strict: boolean): Gesture {
  if (!isRecord(value)) throw new Error(`Gesture ${index + 1} must be an object.`);
  if (strict) assertOnlyKeys(value, ["id", "name", "phrase", "icon", "protected", "risk", "dwellMs", "samples"], `Gesture ${index + 1}`);
  const name = cleanText(value.name, 48, `gesture ${index + 1} name`);
  const phrase = cleanText(strict ? value.phrase : value.phrase ?? "", 240, `${name} phrase`, true);
  const parsedIcon = cleanText(strict ? value.icon : value.icon ?? "•", 8, `${name} icon`, true);
  const icon = strict ? parsedIcon : parsedIcon || "•";
  if (strict && value.risk !== "routine" && value.risk !== "clinical" && value.risk !== "emergency") throw new Error(`${name} risk is invalid.`);
  const risk: RiskLevel = value.risk === "emergency" || value.risk === "clinical" ? value.risk : "routine";
  const defaultDwell = risk === "emergency" ? 1_500 : risk === "clinical" ? 1_000 : 650;
  if (strict && (!Number.isInteger(value.dwellMs) || Number(value.dwellMs) < 350 || Number(value.dwellMs) > 3_000)) throw new Error(`${name} dwellMs must be an integer between 350 and 3000.`);
  const dwellMs = Number.isInteger(value.dwellMs) && Number(value.dwellMs) >= 350 && Number(value.dwellMs) <= 3_000 ? Number(value.dwellMs) : defaultDwell;
  if (strict && !Array.isArray(value.samples)) throw new Error(`${name} samples must be an array.`);
  const rawSamples = Array.isArray(value.samples) ? value.samples : [];
  if (rawSamples.length > 48) throw new Error(`${name} has too many calibration samples.`);
  const samples = rawSamples.map((sample, sampleIndex) => parseSample(sample, name, sampleIndex, strict));
  const id = strict ? requireIdentifier(value.id, `${name} id`) : typeof value.id === "string" && SAFE_IDENTIFIER.test(value.id) ? value.id : `gesture-${index + 1}`;
  if (typeof value.protected !== "undefined" && typeof value.protected !== "boolean") throw new Error(`${name} protected must be boolean.`);
  return { id, name, phrase, icon, protected: value.protected === true, risk, dwellMs, samples };
}

function parseSample(value: unknown, name: string, sampleIndex: number, strict: boolean): GestureSample {
  const record = isRecord(value) ? value : null;
  if (strict && !record) throw new Error(`${name} sample ${sampleIndex + 1} must be an object.`);
  if (strict && record) assertOnlyKeys(record, ["raw", "session", "capturedAt"], `${name} sample ${sampleIndex + 1}`);
  const raw = Array.isArray(record?.raw) ? record.raw : !strict && Array.isArray(value) ? value : null;
  if (!raw || raw.length !== SEQUENCE_LENGTH) throw new Error(`${name} sample ${sampleIndex + 1} must contain ${SEQUENCE_LENGTH} frames.`);
  const frames = raw.map((frame, frameIndex) => {
    if (!Array.isArray(frame)) throw new Error(`${name} sample ${sampleIndex + 1}, frame ${frameIndex + 1} is invalid.`);
    assertFiniteVector(frame, RAW_FRAME_LENGTH, `${name} sample frame`);
    if (frame.some((coordinate) => Math.abs(coordinate) > 10)) throw new Error(`${name} sample ${sampleIndex + 1} contains an out-of-range coordinate.`);
    return frame.map(Number);
  });
  const session = strict ? requireIdentifier(record?.session, `${name} sample session`) : typeof record?.session === "string" && SAFE_IDENTIFIER.test(record.session) ? record.session : "imported";
  const capturedAt = typeof record?.capturedAt === "undefined" ? undefined : requireDateTime(record.capturedAt, `${name} sample capturedAt`);
  return { raw: frames, session, capturedAt };
}

function cleanText(value: unknown, maximum: number, label: string, allowEmpty = false): string {
  if (typeof value !== "string") throw new Error(`${label} must be text.`);
  const result = value.normalize("NFKC").trim();
  if ((!allowEmpty && !result) || result.length > maximum) throw new Error(`${label} must be ${allowEmpty ? `at most ${maximum}` : `1–${maximum}`} characters.`);
  return result;
}
function assertFiniteVector(vector: ReadonlyArray<number>, length: number, label: string): void {
  if (vector.length !== length || vector.some((value) => typeof value !== "number" || !Number.isFinite(value))) throw new Error(`${label} must contain exactly ${length} finite numbers.`);
}
function requireIdentifier(value: unknown, label: string): string {
  if (typeof value !== "string" || !SAFE_IDENTIFIER.test(value)) throw new Error(`${label} must match ${SAFE_IDENTIFIER.source}.`);
  return value;
}
function requireDateTime(value: unknown, label: string): string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value) || !Number.isFinite(Date.parse(value))) throw new Error(`${label} must be an RFC 3339 date-time.`);
  return value;
}
function assertOnlyKeys(value: Record<string, unknown>, allowed: ReadonlyArray<string>, label: string): void {
  const allowedKeys = new Set(allowed);
  const extra = Object.keys(value).find((key) => !allowedKeys.has(key));
  if (extra) throw new Error(`${label} contains unsupported field “${extra}”.`);
}
function isRecord(value: unknown): value is Record<string, unknown> { return typeof value === "object" && value !== null && !Array.isArray(value); }
