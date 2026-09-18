import assert from "node:assert/strict";
import test from "node:test";
import {
  DEFAULT_NEUROFACE_BINDINGS,
  NEUROFACE_RULE_IDS,
  NEUROFACE_RULE_PHRASES,
  NeuroFaceAutoCalibrator,
  NeuroFaceRuleEngine,
  extractNeuroFaceMetrics,
  type NeuroFacePoint,
  type NeuroFaceTwin,
} from "../app/lib/neuroface-rules";

function blankFace(): NeuroFacePoint[] {
  return Array.from({ length: 478 }, () => ({ x: 0.5, y: 0.5 }));
}

function set(face: NeuroFacePoint[], index: number, x: number, y: number): void {
  face[index] = { x, y };
}

/** Relaxed neutral face: EAR ~0.25, centered mouth, zero yaw. */
function neutralFace(): NeuroFacePoint[] {
  const face = blankFace();
  set(face, 33, 0.3, 0.4); set(face, 133, 0.42, 0.4);
  set(face, 160, 0.33, 0.385); set(face, 153, 0.33, 0.415);
  set(face, 158, 0.39, 0.385); set(face, 144, 0.39, 0.415);
  set(face, 263, 0.7, 0.4); set(face, 362, 0.58, 0.4);
  set(face, 385, 0.67, 0.385); set(face, 373, 0.67, 0.415);
  set(face, 387, 0.61, 0.385); set(face, 380, 0.61, 0.415);
  set(face, 1, 0.5, 0.52);
  set(face, 10, 0.5, 0.2); set(face, 152, 0.5, 0.8);
  set(face, 234, 0.2, 0.55); set(face, 454, 0.8, 0.55);
  set(face, 61, 0.42, 0.66); set(face, 291, 0.58, 0.66);
  set(face, 13, 0.5, 0.645); set(face, 14, 0.5, 0.675);
  return face;
}

function closedEyes(face: NeuroFacePoint[]): NeuroFacePoint[] {
  const next = face.map((point) => ({ ...point }));
  set(next, 160, 0.33, 0.398); set(next, 153, 0.33, 0.402);
  set(next, 158, 0.39, 0.398); set(next, 144, 0.39, 0.402);
  set(next, 385, 0.67, 0.398); set(next, 373, 0.67, 0.402);
  set(next, 387, 0.61, 0.398); set(next, 380, 0.61, 0.402);
  return next;
}

function smilingFace(): NeuroFacePoint[] {
  const next = neutralFace();
  set(next, 61, 0.4, 0.645); set(next, 291, 0.6, 0.645);
  set(next, 13, 0.5, 0.64); set(next, 14, 0.5, 0.672);
  return next;
}

function deviatedFace(): NeuroFacePoint[] {
  const next = neutralFace();
  set(next, 61, 0.46, 0.66); set(next, 291, 0.62, 0.66);
  return next;
}

function painFace(): NeuroFacePoint[] {
  const next = neutralFace();
  // squeezed eyes
  set(next, 160, 0.33, 0.394); set(next, 153, 0.33, 0.406);
  set(next, 158, 0.39, 0.394); set(next, 144, 0.39, 0.406);
  set(next, 385, 0.67, 0.394); set(next, 373, 0.67, 0.406);
  set(next, 387, 0.61, 0.394); set(next, 380, 0.61, 0.406);
  // pressed lips + downturned corners
  set(next, 13, 0.5, 0.652); set(next, 14, 0.5, 0.66);
  set(next, 61, 0.42, 0.68); set(next, 291, 0.58, 0.68);
  return next;
}

function headRightFace(): NeuroFacePoint[] {
  const next = neutralFace();
  set(next, 1, 0.58, 0.52);
  return next;
}

function calibrateTwin(): NeuroFaceTwin {
  const calibrator = new NeuroFaceAutoCalibrator(60);
  for (let frame = 0; frame < 60; frame += 1) {
    assert.equal(calibrator.add(neutralFace()), true);
  }
  assert.equal(calibrator.ready, true);
  assert.equal(calibrator.progress, 1);
  return calibrator.finish();
}

test("rule catalogue covers the four patient intents", () => {
  assert.deepEqual([...NEUROFACE_RULE_IDS], [
    "water-5-blinks",
    "feeling-good-smile",
    "emergency-abnormality",
    "food-5-head-right",
  ]);
  assert.equal(NEUROFACE_RULE_PHRASES["water-5-blinks"], "I want water");
  assert.equal(NEUROFACE_RULE_PHRASES["feeling-good-smile"], "I am feeling good");
  assert.equal(NEUROFACE_RULE_PHRASES["emergency-abnormality"], "Emergency help needed");
  assert.equal(NEUROFACE_RULE_PHRASES["food-5-head-right"], "Give me some food");
  assert.equal(DEFAULT_NEUROFACE_BINDINGS["water-5-blinks"], "water");
  assert.equal(DEFAULT_NEUROFACE_BINDINGS["emergency-abnormality"], "emergency");
});

test("neutral metrics are sane and auto-calibration builds a twin", () => {
  const twin = calibrateTwin();
  assert.ok(Math.abs(twin.earMean - 0.25) < 0.02);
  assert.ok(Math.abs(twin.dev0) < 0.01);
  const metrics = extractNeuroFaceMetrics(neutralFace(), twin);
  assert.equal(metrics.facePresent, true);
  assert.ok(Math.abs(metrics.earAvg - 0.25) < 0.02);
  assert.ok(metrics.smile < 0.1);
  assert.ok(Math.abs(metrics.lateralDeviation) < 0.01);
  assert.ok(metrics.painScore < 0.2);
});

test("auto-calibrator rejects frames without a face", () => {
  const calibrator = new NeuroFaceAutoCalibrator(60);
  assert.equal(calibrator.add(null), false);
  assert.equal(calibrator.add([]), false);
  assert.equal(calibrator.ready, false);
  assert.throws(() => calibrator.finish(), /needs 60/);
});

test("five blinks in a row request water; four do not", () => {
  const twin = calibrateTwin();
  const engine = new NeuroFaceRuleEngine(twin);
  let now = 1_000;
  let trigger = null;
  for (let blink = 0; blink < 5; blink += 1) {
    engine.step(neutralFace(), now); now += 100;
    engine.step(closedEyes(neutralFace()), now); now += 100;
    const out = engine.step(neutralFace(), now); now += 400;
    trigger = out.trigger;
  }
  assert.ok(trigger);
  assert.equal(trigger?.rule, "water-5-blinks");

  const short = new NeuroFaceRuleEngine(twin);
  now = 10_000;
  let last = null;
  for (let blink = 0; blink < 4; blink += 1) {
    short.step(neutralFace(), now); now += 100;
    short.step(closedEyes(neutralFace()), now); now += 100;
    last = short.step(neutralFace(), now).trigger; now += 400;
  }
  assert.equal(last, null);
});

test("sustained smile means feeling good; brief smile does not fire", () => {
  const engine = new NeuroFaceRuleEngine(calibrateTwin());
  let now = 1_000;
  let trigger = null;
  for (let frame = 0; frame < 10; frame += 1) {
    now += 100;
    trigger = engine.step(smilingFace(), now).trigger ?? trigger;
  }
  assert.ok(trigger);
  assert.equal(trigger?.rule, "feeling-good-smile");

  const brief = new NeuroFaceRuleEngine(calibrateTwin());
  now = 20_000;
  let fired = null;
  for (let frame = 0; frame < 3; frame += 1) {
    now += 100;
    fired = brief.step(smilingFace(), now).trigger;
  }
  assert.equal(fired, null);
});

test("sustained one-sided deviation raises the emergency abnormality", () => {
  const engine = new NeuroFaceRuleEngine(calibrateTwin());
  let now = 1_000;
  let trigger = null;
  for (let frame = 0; frame < 45; frame += 1) {
    now += 100;
    trigger = engine.step(deviatedFace(), now).trigger ?? trigger;
  }
  assert.ok(trigger);
  assert.equal(trigger?.rule, "emergency-abnormality");

  const centered = new NeuroFaceRuleEngine(calibrateTwin());
  now = 30_000;
  let calm = null;
  for (let frame = 0; frame < 45; frame += 1) {
    now += 100;
    calm = centered.step(neutralFace(), now).trigger;
  }
  assert.equal(calm, null);
});

test("pain/distress movement pattern raises the emergency abnormality", () => {
  const engine = new NeuroFaceRuleEngine(calibrateTwin());
  let now = 1_000;
  let trigger = null;
  for (let frame = 0; frame < 35; frame += 1) {
    now += 100;
    trigger = engine.step(painFace(), now).trigger ?? trigger;
  }
  assert.ok(trigger);
  assert.equal(trigger?.rule, "emergency-abnormality");
});

test("five rightward head turns request food", () => {
  const engine = new NeuroFaceRuleEngine(calibrateTwin());
  let now = 1_000;
  let trigger = null;
  for (let turn = 0; turn < 5; turn += 1) {
    engine.step(headRightFace(), now); now += 200;
    const out = engine.step(neutralFace(), now); now += 200;
    trigger = out.trigger;
  }
  assert.ok(trigger);
  assert.equal(trigger?.rule, "food-5-head-right");
});

test("lost tracking never fires and never crashes", () => {
  const engine = new NeuroFaceRuleEngine(calibrateTwin());
  const out = engine.step(null, 1_000);
  assert.equal(out.trigger, null);
  assert.equal(out.status.metrics?.facePresent, false);
  const uncalibrated = new NeuroFaceRuleEngine(null);
  assert.equal(uncalibrated.step(neutralFace(), 1_000).trigger, null);
  assert.equal(uncalibrated.snapshot().calibrated, false);
});
