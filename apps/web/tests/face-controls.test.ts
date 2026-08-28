import assert from "node:assert/strict";
import test from "node:test";
import {
  createFaceControlEngine,
  createDefaultFaceControlSettings,
  validateFaceControlSettings,
} from "../app/lib/face-controls";
import { DEFAULT_GESTURES } from "../app/lib/fingerspeak";
import type { FaceNeutralBaseline, FaceSignals } from "../app/lib/face-intent";

test("default face controls bind deliberate movements to existing communication phrases", () => {
  const settings = createDefaultFaceControlSettings("local-profile", new Date("2026-08-22T00:00:00Z"));

  assert.equal(settings.bindings.blink, "yes");
  assert.equal(settings.bindings["eyes-right"], "water");
  assert.equal(settings.baseline, null);
  assert.equal(validateFaceControlSettings(settings).enabled, true);
});

test("face controls reject unsafe gesture identifiers", () => {
  const settings = createDefaultFaceControlSettings("local-profile");
  settings.bindings.blink = "../../unsafe";

  assert.throws(() => validateFaceControlSettings(settings), /gesture id is invalid/);
});

test("mapped phrase safety dwell controls face activation time", () => {
  const settings = createDefaultFaceControlSettings("local-profile");
  settings.baseline = neutralBaseline();
  settings.bindings.blink = "emergency";
  const engine = createFaceControlEngine(settings, DEFAULT_GESTURES);
  const active = faceSignals({ blink: .9 });

  assert.equal(engine.step(active, 0).trigger, null);
  assert.equal(engine.step(active, 1_500).trigger, null);
  assert.equal(engine.step(active, 1_580).trigger?.id, "blink");
});

test("unassigned face movements are disabled", () => {
  const settings = createDefaultFaceControlSettings("local-profile");
  settings.baseline = neutralBaseline();
  settings.bindings.blink = null;
  const engine = createFaceControlEngine(settings, DEFAULT_GESTURES);

  assert.equal(engine.step(faceSignals({ blink: .9 }), 0).phase, "IDLE");
});

function neutralBaseline(): FaceNeutralBaseline {
  const metric = { center: 0, noise: .001 };
  return {
    version: 1,
    sampleCount: 30,
    blink: { ...metric },
    gazeHorizontal: { ...metric },
    browsUp: { ...metric },
    mouthOpen: { ...metric },
  };
}

function faceSignals(overrides: Partial<FaceSignals> = {}): FaceSignals {
  return {
    facePresent: true,
    blink: 0,
    gazeHorizontal: 0,
    browsUp: 0,
    mouthOpen: 0,
    source: "blendshapes",
    ...overrides,
  };
}
