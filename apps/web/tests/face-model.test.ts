import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";

const OFFICIAL_FACE_LANDMARKER_SHA256 = "64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff";

test("bundled MediaPipe Face Landmarker matches the pinned official model", () => {
  const model = readFileSync(new URL("../public/models/face_landmarker.task", import.meta.url));
  assert.equal(model.byteLength, 3_758_596);
  assert.equal(createHash("sha256").update(model).digest("hex"), OFFICIAL_FACE_LANDMARKER_SHA256);
});
