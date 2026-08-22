import {
  CONFIDENCE_THRESHOLD,
  FEATURE_LENGTH,
  OOD_REJECT_MULTIPLIER,
  SEQUENCE_LENGTH,
  profileModelFingerprint,
  type FingerSpeakProfile,
  type PrototypeModel,
  type RiskLevel,
} from "./fingerspeak";

const BUNDLE_SCHEMA_VERSION = 1;
const RAW_FEATURE_LENGTH = 63;
const SUMMARY_LENGTH = FEATURE_LENGTH * 2;
const MIN_SPREAD = 0.05;
const MAX_MANIFEST_BYTES = 2_000_000;
const MAX_EDGE_BYTES = 10_000_000;
const SAFE_IDENTIFIER = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$/;

type ManifestClass = {
  index: number;
  gestureId: string;
  name: string;
  phrase: string;
  icon: string;
  isRest: boolean;
  risk: RiskLevel;
  confidenceThreshold: number;
  dwellMs: number;
};

type ParsedManifest = {
  createdAt: string;
  classes: ManifestClass[];
  edgePath: string;
  edgeSize: number;
  edgeSha256: string;
};

export async function importPrototypeBundle(files: ReadonlyArray<File>, profile: FingerSpeakProfile): Promise<PrototypeModel> {
  const manifestFile = files.find((file) => file.name === "manifest.json");
  if (!manifestFile) throw new Error("Select manifest.json and edge-prototype.json together.");
  if (manifestFile.size > MAX_MANIFEST_BYTES) throw new Error("Model manifest is too large.");

  const manifest = parseManifest(JSON.parse(await manifestFile.text()));
  const expectedName = manifest.edgePath.split("/").at(-1);
  const edgeFile = files.find((file) => file.name === expectedName);
  if (!edgeFile) throw new Error(`Select the manifest-referenced ${expectedName} file too.`);
  if (edgeFile.size !== manifest.edgeSize || edgeFile.size > MAX_EDGE_BYTES) throw new Error("Edge model byte length does not match its signed manifest.");

  const edgeBytes = await edgeFile.arrayBuffer();
  const actualSha256 = await sha256Hex(edgeBytes);
  if (actualSha256 !== manifest.edgeSha256.toLowerCase()) throw new Error("Edge model checksum does not match its manifest.");

  const edge = parseEdgeArtifact(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(edgeBytes)));
  const manifestIds = manifest.classes.map((item) => item.gestureId);
  const edgeIds = edge.prototypes.map((item) => item.gestureId);
  if (!sameOrderedValues(manifestIds, edgeIds)) throw new Error("Manifest classes and edge prototypes are ordered differently.");

  const profileIds = profile.gestures.map((gesture) => gesture.id);
  if (!sameOrderedValues(manifestIds, profileIds)) throw new Error("This model was trained for a different gesture profile. Import the matching profile first.");
  for (const [index, gesture] of profile.gestures.entries()) {
    const modelClass = manifest.classes[index];
    if (
      modelClass.name !== gesture.name ||
      modelClass.phrase !== gesture.phrase ||
      modelClass.risk !== gesture.risk ||
      modelClass.dwellMs !== gesture.dwellMs
    ) {
      throw new Error(`Safety policy mismatch for gesture “${gesture.name}”. Import the matching profile before activating this model.`);
    }
  }

  return {
    featureVersion: "3d-angle-motion-v1",
    sequenceLength: SEQUENCE_LENGTH,
    featureLength: FEATURE_LENGTH,
    profileFingerprint: await profileModelFingerprint(profile),
    prototypes: edge.prototypes.map((prototype) => ({
      gestureId: prototype.gestureId,
      centroid: prototype.centroid,
      spread: prototype.spread,
    })),
    trainedAt: manifest.createdAt,
  };
}

function parseManifest(value: unknown): ParsedManifest {
  const root = record(value, "Model manifest");
  if (root.schema_version !== BUNDLE_SCHEMA_VERSION) throw new Error("Unsupported model bundle version.");
  const createdAt = text(root.created_at, 64, "created_at");
  if (!Number.isFinite(Date.parse(createdAt))) throw new Error("Model created_at must be an ISO timestamp.");

  const feature = record(root.feature, "Manifest feature contract");
  if (
    feature.version !== "3d-angle-motion-v1" ||
    feature.sequence_length !== SEQUENCE_LENGTH ||
    feature.raw_feature_length !== RAW_FEATURE_LENGTH ||
    feature.engineered_feature_length !== FEATURE_LENGTH
  ) throw new Error("Model feature contract is incompatible with this app.");

  if (!Array.isArray(root.classes) || root.classes.length < 2 || root.classes.length > 24) throw new Error("Model manifest must contain 2–24 classes.");
  const classes = root.classes.map((item, index) => parseManifestClass(item, index));
  if (new Set(classes.map((item) => item.gestureId)).size !== classes.length) throw new Error("Model gesture IDs must be unique.");
  if (classes.filter((item) => item.isRest).length !== 1 || !classes.some((item) => item.isRest && item.gestureId === "rest")) throw new Error("Model manifest must contain exactly one Rest class.");

  if (!Array.isArray(root.models)) throw new Error("Model manifest has no models list.");
  const prototypeModels = root.models.filter((item) => isRecord(item) && item.type === "nearest-prototype");
  if (prototypeModels.length !== 1) throw new Error("Model manifest must reference exactly one nearest-prototype artifact.");
  const edgePath = safeArtifactPath(record(prototypeModels[0], "Prototype model").artifact);

  const ood = record(root.ood, "OOD policy");
  if (ood.type !== "summary-centroid" || ood.multiplier !== OOD_REJECT_MULTIPLIER || ood.artifact !== edgePath) throw new Error("Model OOD policy is incompatible with this app.");
  if (!Array.isArray(root.artifacts)) throw new Error("Model manifest has no artifact checksums.");
  const descriptors = root.artifacts.filter((item) => isRecord(item) && item.path === edgePath);
  if (descriptors.length !== 1) throw new Error("Model manifest must contain one checksum for the edge artifact.");
  const descriptor = descriptors[0];
  if (!Number.isInteger(descriptor.size) || Number(descriptor.size) < 1 || Number(descriptor.size) > MAX_EDGE_BYTES) throw new Error("Edge artifact size is invalid.");
  if (typeof descriptor.sha256 !== "string" || !/^[a-fA-F0-9]{64}$/.test(descriptor.sha256)) throw new Error("Edge artifact SHA-256 is invalid.");

  return { createdAt, classes, edgePath, edgeSize: Number(descriptor.size), edgeSha256: descriptor.sha256 };
}

function parseManifestClass(value: unknown, index: number): ManifestClass {
  const item = record(value, `Model class ${index + 1}`);
  if (item.index !== index) throw new Error("Model class indices must be contiguous and ordered.");
  const gestureId = text(item.gesture_id, 80, "gesture_id");
  if (!SAFE_IDENTIFIER.test(gestureId)) throw new Error("Model gesture_id is unsafe.");
  const name = text(item.name, 48, "class name");
  const phrase = text(item.phrase, 240, "class phrase", true);
  const icon = text(item.icon, 8, "class icon", true);
  if (typeof item.is_rest !== "boolean") throw new Error("Model is_rest must be boolean.");
  if (item.risk !== "routine" && item.risk !== "clinical" && item.risk !== "emergency") throw new Error("Model risk is invalid.");
  if (item.confidence_threshold !== CONFIDENCE_THRESHOLD) throw new Error(`Model confidence threshold must be ${CONFIDENCE_THRESHOLD}.`);
  if (!Number.isInteger(item.dwell_ms) || Number(item.dwell_ms) < 350 || Number(item.dwell_ms) > 3_000) throw new Error("Model dwell time is outside the safe range.");
  return {
    index,
    gestureId,
    name,
    phrase,
    icon,
    isRest: item.is_rest,
    risk: item.risk,
    confidenceThreshold: item.confidence_threshold,
    dwellMs: Number(item.dwell_ms),
  };
}

function parseEdgeArtifact(value: unknown): { prototypes: Array<{ gestureId: string; centroid: number[]; spread: number }> } {
  const root = record(value, "Edge prototype artifact");
  if (root.schema_version !== BUNDLE_SCHEMA_VERSION) throw new Error("Unsupported edge prototype version.");
  const feature = record(root.feature, "Edge feature contract");
  if (
    feature.version !== "3d-angle-motion-v1" ||
    feature.sequence_length !== SEQUENCE_LENGTH ||
    feature.feature_length !== FEATURE_LENGTH ||
    feature.summary_length !== SUMMARY_LENGTH ||
    root.confidence_threshold !== CONFIDENCE_THRESHOLD ||
    root.ood_multiplier !== OOD_REJECT_MULTIPLIER
  ) throw new Error("Edge model constants are incompatible with this app.");
  if (!Array.isArray(root.prototypes) || root.prototypes.length < 2 || root.prototypes.length > 24) throw new Error("Edge model must contain 2–24 prototypes.");
  const prototypes = root.prototypes.map((value, index) => {
    const item = record(value, `Edge prototype ${index + 1}`);
    const gestureId = text(item.gesture_id, 80, "prototype gesture_id");
    if (!SAFE_IDENTIFIER.test(gestureId)) throw new Error("Prototype gesture_id is unsafe.");
    if (!Array.isArray(item.centroid) || item.centroid.length !== SUMMARY_LENGTH || item.centroid.some((number) => typeof number !== "number" || !Number.isFinite(number) || Math.abs(number) > 1_000_000)) throw new Error(`Prototype centroid must contain ${SUMMARY_LENGTH} bounded finite numbers.`);
    if (typeof item.spread !== "number" || !Number.isFinite(item.spread) || item.spread < MIN_SPREAD || item.spread > 1_000_000) throw new Error(`Prototype spread must be between ${MIN_SPREAD} and 1000000.`);
    return { gestureId, centroid: item.centroid.map(Number), spread: item.spread };
  });
  if (new Set(prototypes.map((item) => item.gestureId)).size !== prototypes.length) throw new Error("Prototype gesture IDs must be unique.");
  return { prototypes };
}

async function sha256Hex(bytes: ArrayBuffer): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function safeArtifactPath(value: unknown): string {
  const path = text(value, 240, "artifact path");
  if (path.startsWith("/") || path.split("/").includes("..") || path.includes("\\")) throw new Error("Model artifact path is unsafe.");
  return path;
}

function sameOrderedValues(left: ReadonlyArray<string>, right: ReadonlyArray<string>): boolean {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

function text(value: unknown, maximum: number, label: string, allowEmpty = false): string {
  if (typeof value !== "string" || value.length > maximum || (!allowEmpty && !value.trim())) throw new Error(`${label} is invalid.`);
  return value;
}

function record(value: unknown, label: string): Record<string, unknown> {
  if (!isRecord(value)) throw new Error(`${label} must be an object.`);
  return value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
