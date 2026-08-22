import assert from "node:assert/strict";
import { File as NodeFile } from "node:buffer";
import { createHash } from "node:crypto";
import test from "node:test";
import { createDefaultProfile } from "../app/lib/fingerspeak";
import { importPrototypeBundle } from "../app/lib/model-bundle";

function bundleFiles(tamperChecksum = false): File[] {
  const profile = createDefaultProfile();
  const edge = JSON.stringify({
    schema_version: 1,
    feature: { version: "3d-angle-motion-v1", sequence_length: 20, feature_length: 98, summary_length: 196 },
    confidence_threshold: 0.72,
    ood_multiplier: 2.2,
    prototypes: profile.gestures.map((gesture, index) => ({ gesture_id: gesture.id, centroid: new Array(196).fill(index / 10), spread: 0.05 })),
  });
  const digest = createHash("sha256").update(edge).digest("hex");
  const manifest = JSON.stringify({
    schema_version: 1,
    created_at: "2026-08-15T00:00:00Z",
    feature: { version: "3d-angle-motion-v1", sequence_length: 20, raw_feature_length: 63, engineered_feature_length: 98 },
    classes: profile.gestures.map((gesture, index) => ({
      index,
      gesture_id: gesture.id,
      name: gesture.name,
      phrase: gesture.phrase,
      icon: gesture.icon,
      is_rest: gesture.id === "rest",
      risk: gesture.risk,
      confidence_threshold: 0.72,
      dwell_ms: gesture.dwellMs,
    })),
    models: [{ type: "nearest-prototype", artifact: "edge-prototype.json" }],
    ood: { type: "summary-centroid", artifact: "edge-prototype.json", multiplier: 2.2 },
    metrics: {},
    artifacts: [{ path: "edge-prototype.json", sha256: tamperChecksum ? "0".repeat(64) : digest, size: Buffer.byteLength(edge) }],
  });
  return [
    new NodeFile([manifest], "manifest.json", { type: "application/json" }) as unknown as File,
    new NodeFile([edge], "edge-prototype.json", { type: "application/json" }) as unknown as File,
  ];
}

test("a checksummed Python prototype bundle binds by stable gesture ID", async () => {
  const profile = createDefaultProfile();
  const model = await importPrototypeBundle(bundleFiles(), profile);
  assert.deepEqual(model.prototypes.map((prototype) => prototype.gestureId), profile.gestures.map((gesture) => gesture.id));
  assert.equal(model.prototypes[0].centroid.length, 196);
  assert.match(model.profileFingerprint, /^[a-f0-9]{64}$/);
});

test("a tampered edge model is rejected before activation", async () => {
  await assert.rejects(importPrototypeBundle(bundleFiles(true), createDefaultProfile()), /checksum/);
});
