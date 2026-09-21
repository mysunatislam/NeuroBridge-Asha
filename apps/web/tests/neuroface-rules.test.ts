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

function headTurnedClosedEyes(): NeuroFacePoint[] {
  const next = closedEyes(neutralFace());
  set(next, 1, 0.58, 0.52); // Yaw offset
  return next;
}

function headRightFace(): NeuroFacePoint[] {
  const next = neutralFace();
  set(next, 1, 0.58, 0.52);
  return next;
}

function headLeftFace(): NeuroFacePoint[] {
  const next = neutralFace();
  set(next, 1, 0.42, 0.52);
  return next;
}

function smilingFace(): NeuroFacePoint[] {
  const next = neutralFace();
  set(next, 61, 0.4, 0.645); set(next, 291, 0.6, 0.645);
  set(next, 13, 0.5, 0.64); set(next, 14, 0.5, 0.672);
  return next;
}

function smilingNodUpFace(): NeuroFacePoint[] {
  const next = smilingFace();
  set(next, 1, 0.5, 0.48);
  return next;
}

function smilingNodDownFace(): NeuroFacePoint[] {
  const next = smilingFace();
  set(next, 1, 0.5, 0.56);
  return next;
}

function nodUpFace(): NeuroFacePoint[] {
  const next = neutralFace();
  set(next, 1, 0.5, 0.48);
  return next;
}

function nodDownFace(): NeuroFacePoint[] {
  const next = neutralFace();
  set(next, 1, 0.5, 0.56);
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

test("rule catalogue covers the four NeuroSense intents", () => {
  assert.deepEqual([...NEUROFACE_RULE_IDS], [
    "water-3-blinks",
    "food-3-head-left",
    "toilet-3-head-right",
    "okay-nod-smile",
  ]);
  assert.equal(NEUROFACE_RULE_PHRASES["water-3-blinks"], "I need water");
  assert.equal(NEUROFACE_RULE_PHRASES["food-3-head-left"], "I need food");
  assert.equal(NEUROFACE_RULE_PHRASES["toilet-3-head-right"], "I need to go to toilet");
  assert.equal(NEUROFACE_RULE_PHRASES["okay-nod-smile"], "I am okay, thank you");
  assert.equal(DEFAULT_NEUROFACE_BINDINGS["water-3-blinks"], "water");
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

test("three blinks looking at camera request water; two do not", () => {
  const engine = new NeuroFaceRuleEngine(calibrateTwin());
  let now = 1_000;
  let trigger = null;
  for (let blink = 0; blink < 3; blink += 1) {
    engine.step(neutralFace(), now); now += 100;
    engine.step(closedEyes(neutralFace()), now); now += 100;
    const out = engine.step(neutralFace(), now); now += 400;
    trigger = out.trigger;
  }
  assert.ok(trigger);
  assert.equal(trigger?.rule, "water-3-blinks");

  const short = new NeuroFaceRuleEngine(calibrateTwin());
  now = 10_000;
  let last = null;
  for (let blink = 0; blink < 2; blink += 1) {
    short.step(neutralFace(), now); now += 100;
    short.step(closedEyes(neutralFace()), now); now += 100;
    last = short.step(neutralFace(), now).trigger; now += 400;
  }
  assert.equal(last, null);
});

test("blinks with head turned do NOT fire water (gaze-gate)", () => {
  const engine = new NeuroFaceRuleEngine(calibrateTwin());
  let now = 1_000;
  let trigger = null;
  for (let blink = 0; blink < 3; blink += 1) {
    engine.step(headRightFace(), now); now += 100;
    engine.step(headTurnedClosedEyes(), now); now += 100;
    const out = engine.step(headRightFace(), now); now += 400;
    trigger = out.trigger;
  }
  assert.equal(trigger, null);
});

test("three leftward head turns request food", () => {
  const engine = new NeuroFaceRuleEngine(calibrateTwin());
  let now = 1_000;
  let trigger = null;
  for (let turn = 0; turn < 3; turn += 1) {
    engine.step(headLeftFace(), now); now += 200;
    const out = engine.step(neutralFace(), now); now += 200;
    trigger = out.trigger;
  }
  assert.ok(trigger);
  assert.equal(trigger?.rule, "food-3-head-left");
});

test("three rightward head turns request toilet", () => {
  const engine = new NeuroFaceRuleEngine(calibrateTwin());
  let now = 1_000;
  let trigger = null;
  for (let turn = 0; turn < 3; turn += 1) {
    engine.step(headRightFace(), now); now += 200;
    const out = engine.step(neutralFace(), now); now += 200;
    trigger = out.trigger;
  }
  assert.ok(trigger);
  assert.equal(trigger?.rule, "toilet-3-head-right");
});

test("nodding while smiling fires okay", () => {
  const engine = new NeuroFaceRuleEngine(calibrateTwin());
  let now = 1_000;
  let trigger = null;
  
  // Neutral smile start
  engine.step(smilingFace(), now); now += 200;
  
  // Nod oscillation: up -> down -> up -> down (each takes some frames)
  for (let step of [smilingNodUpFace(), smilingNodDownFace(), smilingNodUpFace(), smilingNodDownFace(), smilingFace()]) {
    const out = engine.step(step, now); now += 200;
    if (out.trigger) trigger = out.trigger;
  }
  
  assert.ok(trigger);
  assert.equal(trigger?.rule, "okay-nod-smile");
});

test("nodding without smile does NOT fire", () => {
  const engine = new NeuroFaceRuleEngine(calibrateTwin());
  let now = 1_000;
  let trigger = null;
  
  engine.step(neutralFace(), now); now += 200;
  
  for (let step of [nodUpFace(), nodDownFace(), nodUpFace(), nodDownFace(), neutralFace()]) {
    const out = engine.step(step, now); now += 200;
    if (out.trigger) trigger = out.trigger;
  }
  
  assert.equal(trigger, null);
});

test("smile without nodding does NOT fire", () => {
  const engine = new NeuroFaceRuleEngine(calibrateTwin());
  let now = 1_000;
  let trigger = null;
  for (let frame = 0; frame < 10; frame += 1) {
    now += 100;
    const out = engine.step(smilingFace(), now);
    if (out.trigger) trigger = out.trigger;
  }
  assert.equal(trigger, null);
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

test("single deliberate blink emits blink-select", () => {
  const engine = new NeuroFaceRuleEngine(calibrateTwin());
  let now = 1_000;
  engine.step(neutralFace(), now); now += 50;
  engine.step(closedEyes(neutralFace()), now); now += 250;
  const openResult = engine.step(neutralFace(), now); now += 50;
  assert.equal(openResult.status.navEvent, "blink-select");

  const nextFrame = engine.step(neutralFace(), now);
  assert.equal(nextFrame.status.navEvent, null);
});

test("head turn emits edge-triggered nav-left and nav-right", () => {
  const engine = new NeuroFaceRuleEngine(calibrateTwin());
  let now = 1_000;
  engine.step(neutralFace(), now); now += 100;

  const left1 = engine.step(headLeftFace(), now); now += 100;
  assert.equal(left1.status.navEvent, "nav-left");

  const left2 = engine.step(headLeftFace(), now); now += 100;
  assert.equal(left2.status.navEvent, null);

  engine.step(neutralFace(), now); now += 200;

  const right1 = engine.step(headRightFace(), now); now += 100;
  assert.equal(right1.status.navEvent, "nav-right");

  const right2 = engine.step(headRightFace(), now);
  assert.equal(right2.status.navEvent, null);
});
