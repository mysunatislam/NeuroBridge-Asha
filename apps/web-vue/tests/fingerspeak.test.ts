import assert from "node:assert/strict";
import test from "node:test";
import {
  FEATURE_LENGTH,
  PROFILE_VERSION,
  addVelocity,
  buildModelInput,
  computeFrameFeatures,
  dtwDistance,
  parseProfile,
  profileModelFingerprint,
  resampleSequence,
} from "../src/lib/fingerspeak";

const canonical = [
  [0, 0, 0], [-.45, .25, .02], [-.65, .5, .03], [-.78, .72, .02], [-.9, .9, 0],
  [-.48, .58, 0], [-.5, .95, -.01], [-.5, 1.25, -.02], [-.5, 1.55, -.03],
  [0, .68, 0], [0, 1.08, -.01], [0, 1.43, -.02], [0, 1.76, -.03],
  [.42, .61, 0], [.45, .98, -.01], [.47, 1.29, -.02], [.49, 1.56, -.03],
  [.78, .5, .01], [.83, .82, 0], [.87, 1.08, -.01], [.9, 1.3, -.02],
] as const;

function hand(theta = 0, translateX = 0, translateY = 0, size = 1): number[] {
  const cosine = Math.cos(theta);
  const sine = Math.sin(theta);
  return canonical.flatMap(([x, y, z]) => [
    (x * cosine - y * sine) * size + translateX,
    (x * sine + y * cosine) * size + translateY,
    z * size,
  ]);
}

test("feature pipeline is rotation, translation, and scale invariant", () => {
  const baseline = computeFrameFeatures(hand());
  const transformed = computeFrameFeatures(hand(.72, 3.4, -1.8, 2.6));
  assert.equal(baseline.length, 83);
  const maximumDifference = Math.max(...baseline.map((value, index) => Math.abs(value - transformed[index])));
  assert.ok(maximumDifference < 1e-8, `maximum invariant feature drift was ${maximumDifference}`);
});

test("model input adds fingertip velocity without changing shape", () => {
  const sequence = Array.from({ length: 20 }, (_, index) => hand(0, index * .001));
  const features = buildModelInput(sequence);
  assert.equal(features.length, 20);
  assert.ok(features.every((frame) => frame.length === FEATURE_LENGTH));
  assert.deepEqual(addVelocity(features.map((frame) => frame.slice(0, 83)))[0].slice(83), new Array(15).fill(0));
});

test("resampling interpolates a complete fixed-size sequence", () => {
  const frames = Array.from({ length: 10 }, (_, index) => ({ t: index * 100, raw: hand(0, index * .01) }));
  const result = resampleSequence(frames, 20, 900);
  assert.equal(result?.length, 20);
  assert.ok(result?.every((frame) => frame.length === 63));
});

test("DTW prefers the same motion over an unrelated sequence", () => {
  const motion = Array.from({ length: 8 }, (_, index) => [index / 7, Math.sin(index / 2)]);
  const warped = [motion[0], motion[1], motion[1], motion[3], motion[4], motion[4], motion[6], motion[7]];
  const unrelated = motion.map(([value]) => [1 - value, -2]);
  assert.ok(dtwDistance(motion, warped) < dtwDistance(motion, unrelated));
  assert.equal(dtwDistance(motion, motion), 0);
});

test("profile import validates dimensions and preserves icon text inertly", () => {
  const sample = { raw: Array.from({ length: 20 }, () => hand()), session: "s1" };
  const payload = createProfilePayload();
  payload.gestures[0].icon = "<svg>";
  payload.gestures[0].samples = [sample];
  payload.gestures[1].samples = [sample];
  const profile = parseProfile(payload);
  assert.equal(profile.gestures[0].icon, "<svg>");
  assert.throws(() => parseProfile({ version: 3, gestures: [{ name: "Rest", samples: [] }] }));
});

test("file import resets cloud consent while trusted device reload preserves it", () => {
  const payload = {
    ...createProfilePayload(),
    consentToEventSync: true,
    consentToCaregiverAlerts: true,
  };
  assert.equal(parseProfile(payload).consentToEventSync, false);
  assert.equal(parseProfile(payload, { preserveLocalConsent: true }).consentToEventSync, true);
});

test("saved calibration timestamps preserve the model fingerprint across reload", async () => {
  const payload = createProfilePayload();
  payload.gestures[1].samples.push({
    raw: Array.from({ length: 20 }, () => hand()),
    session: "session-1",
    capturedAt: "2026-08-15T00:00:00.000Z",
  });
  const first = parseProfile(payload, { preserveLocalConsent: true });
  const reloaded = parseProfile(first, { preserveLocalConsent: true });
  assert.equal(reloaded.gestures[1].samples[0].capturedAt, "2026-08-15T00:00:00.000Z");
  assert.equal(await profileModelFingerprint(first), await profileModelFingerprint(reloaded));
});

test("profile import rejects duplicate IDs and names", () => {
  const payload = createProfilePayload();
  payload.gestures.push({ id: "yes", name: "Affirm", phrase: "Yes.", icon: "✓", risk: "routine", dwellMs: 650, protected: false, samples: [] });
  assert.throws(() => parseProfile(payload), /IDs must be unique/);
});

test("non-finite landmark coordinates are rejected", () => {
  const invalid = hand();
  invalid[8] = Number.NaN;
  assert.throws(() => computeFrameFeatures(invalid), /finite numbers/);
});

function createProfilePayload() {
  return {
    version: PROFILE_VERSION,
    id: "safe-profile",
    name: "Test",
    updatedAt: new Date().toISOString(),
    gestures: [
      { id: "rest", name: "Rest", phrase: "", icon: "✋", risk: "routine", dwellMs: 500, protected: true, samples: [] as Array<{ raw: number[][]; session: string; capturedAt?: string }> },
      { id: "yes", name: "Yes", phrase: "Yes.", icon: "👍", risk: "routine", dwellMs: 650, protected: false, samples: [] as Array<{ raw: number[][]; session: string; capturedAt?: string }> },
    ],
  };
}
