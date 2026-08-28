import assert from "node:assert/strict";
import test from "node:test";
import {
  FaceIntentEngine,
  NeutralFaceCalibrator,
  buildNeutralFaceBaseline,
  extractFaceSignals,
  type FaceBlendshapeCategoryLike,
  type FaceLandmarkLike,
  type FaceNeutralBaseline,
  type FaceSignals,
} from "../app/lib/face-intent";

function blendshapeResult(scores: Record<string, number>) {
  const categories: FaceBlendshapeCategoryLike[] = Object.entries(scores)
    .map(([categoryName, score], index) => ({ categoryName, score, index }));
  return { faceBlendshapes: [{ categories }], faceLandmarks: [[]] };
}

function signals(overrides: Partial<FaceSignals> = {}): FaceSignals {
  return {
    facePresent: true,
    blink: .08,
    gazeHorizontal: .04,
    browsUp: .1,
    mouthOpen: .05,
    source: "blendshapes",
    ...overrides,
  };
}

function baseline(): FaceNeutralBaseline {
  return buildNeutralFaceBaseline(Array.from({ length: 20 }, (_, index) => signals({
    blink: .08 + (index % 3) * .001,
    gazeHorizontal: .04 + (index % 3) * .001,
    browsUp: .1 + (index % 3) * .001,
    mouthOpen: .05 + (index % 3) * .001,
  })));
}

test("extracts movement signals from MediaPipe blendshapes", () => {
  const result = extractFaceSignals(blendshapeResult({
    eyeBlinkLeft: .9,
    eyeBlinkRight: .82,
    eyeLookOutLeft: .75,
    eyeLookInRight: .65,
    eyeLookInLeft: .1,
    eyeLookOutRight: .2,
    browInnerUp: .45,
    browOuterUpLeft: .55,
    browOuterUpRight: .5,
    jawOpen: .72,
  }));

  assert.equal(result.facePresent, true);
  assert.equal(result.source, "blendshapes");
  assert.equal(result.blink, .82);
  assert.ok(Math.abs((result.gazeHorizontal ?? 0) - -.55) < 1e-12);
  assert.equal(result.browsUp, .5);
  assert.equal(result.mouthOpen, .72);
});

test("uses landmark geometry when blendshape output is disabled", () => {
  const landmarks = landmarkFace();
  const normal = extractFaceSignals({ faceLandmarks: [landmarks], faceBlendshapes: [] });
  const mirrored = extractFaceSignals(
    { faceLandmarks: [landmarks], faceBlendshapes: [] },
    { mirrorHorizontal: true },
  );

  assert.equal(normal.source, "landmarks");
  assert.ok(normal.blink !== null && normal.blink < .5);
  assert.ok(normal.gazeHorizontal !== null && normal.gazeHorizontal < 0);
  assert.equal(mirrored.gazeHorizontal, -(normal.gazeHorizontal ?? 0));
  assert.ok((normal.browsUp ?? 0) > 0);
  assert.ok((normal.mouthOpen ?? 0) > 0);
});

test("neutral calibration ignores incomplete frames and uses a robust median", () => {
  const calibrator = new NeutralFaceCalibrator(5, 10);
  assert.equal(calibrator.add(signals({ facePresent: false })), false);
  assert.equal(calibrator.add(signals({ mouthOpen: null })), false);
  [.05, .051, .052, .053, .9]
    .forEach((mouthOpen) => assert.equal(calibrator.add(signals({ mouthOpen })), true));

  assert.equal(calibrator.ready, true);
  assert.equal(calibrator.progress, 1);
  const result = calibrator.finish();
  assert.equal(result.sampleCount, 5);
  assert.equal(result.mouthOpen.center, .052);
  assert.ok(result.mouthOpen.noise < .01);
});

test("requires calibration before creating an intent", () => {
  const engine = new FaceIntentEngine();
  const output = engine.step(signals({ blink: .9 }), 0);
  assert.equal(output.phase, "CALIBRATION_REQUIRED");
  assert.equal(output.trigger, null);
});

test("debounces, holds, emits once, then requires cooldown and release", () => {
  const engine = new FaceIntentEngine(baseline(), {
    rules: {
      blink: { minimumDelta: .2, debounceMs: 40, holdMs: 80, cooldownMs: 200, releaseRatio: .4 },
    },
  });
  const active = signals({ blink: .8 });
  const neutral = signals();

  assert.equal(engine.step(active, 0).phase, "DEBOUNCE");
  assert.equal(engine.step(active, 39).trigger, null);
  assert.equal(engine.step(active, 40).phase, "HOLD");
  const fired = engine.step(active, 120);
  assert.equal(fired.trigger?.id, "blink");
  assert.equal(fired.phase, "COOLDOWN");
  assert.equal(engine.step(active, 250).trigger, null);
  assert.equal(engine.step(active, 320).phase, "WAIT_RELEASE");
  assert.equal(engine.step(neutral, 321).phase, "IDLE");
  assert.equal(engine.step(active, 322).phase, "DEBOUNCE");
});

test("uses the neutral gaze baseline to distinguish left from right", () => {
  const engine = new FaceIntentEngine(baseline(), {
    rules: {
      "eyes-left": { minimumDelta: .2, debounceMs: 0, holdMs: 0 },
      "eyes-right": { minimumDelta: .2, debounceMs: 0, holdMs: 0 },
    },
  });
  const output = engine.step(signals({ gazeHorizontal: -.4 }), 10);
  assert.equal(output.trigger?.id, "eyes-left");
  assert.ok(output.activationRatios["eyes-left"] >= 1);
  assert.equal(output.activationRatios["eyes-right"], 0);
});

test("a missing face resets a partial hold", () => {
  const engine = new FaceIntentEngine(baseline(), {
    rules: { "mouth-open": { minimumDelta: .2, debounceMs: 50, holdMs: 100 } },
  });
  const active = signals({ mouthOpen: .6 });
  engine.step(active, 0);
  assert.equal(engine.step(active, 75).phase, "HOLD");
  assert.equal(engine.step(signals({ facePresent: false }), 90).phase, "NO_FACE");
  assert.equal(engine.step(active, 200).phase, "DEBOUNCE");
  assert.equal(engine.step(active, 250).trigger, null);
});

test("neutral baseline rejects too few complete samples", () => {
  assert.throws(() => buildNeutralFaceBaseline([signals()], 2), /at least 2/);
});

function landmarkFace(): FaceLandmarkLike[] {
  const points: FaceLandmarkLike[] = Array.from({ length: 478 }, () => ({ x: .5, y: .5, z: 0 }));
  const set = (index: number, x: number, y: number) => { points[index] = { x, y, z: 0 }; };

  set(33, .2, .4); set(133, .4, .4);
  set(160, .25, .38); set(144, .25, .42); set(158, .35, .38); set(153, .35, .42);
  set(468, .36, .4);
  set(362, .6, .4); set(263, .8, .4);
  set(385, .65, .38); set(380, .65, .42); set(387, .75, .38); set(373, .75, .42);
  set(473, .76, .4);
  set(70, .25, .31); set(105, .35, .31); set(334, .65, .31); set(300, .75, .31);
  set(13, .5, .61); set(14, .5, .65); set(78, .4, .63); set(308, .6, .63);
  return points;
}
