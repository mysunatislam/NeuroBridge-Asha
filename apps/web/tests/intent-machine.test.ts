import assert from "node:assert/strict";
import test from "node:test";
import { DEFAULT_GESTURES } from "../app/lib/fingerspeak";
import { IntentMachine } from "../app/lib/intent-machine";

const gestures = structuredClone(DEFAULT_GESTURES);
const confidentYes = { handPresent: true, gestureId: "yes", confidence: .95, inDistribution: true };
const rest = { handPresent: true, gestureId: "rest", confidence: .95, inDistribution: true };

test("a stable gesture fires once and requires release", () => {
  const machine = new IntentMachine(.7, 3);
  assert.equal(machine.step(confidentYes, 0, gestures).state, "CANDIDATE");
  assert.equal(machine.step(confidentYes, 400, gestures).trigger, null);
  const confirmed = machine.step(confidentYes, 700, gestures);
  assert.equal(confirmed.trigger?.id, "yes");
  assert.equal(confirmed.state, "WAIT_RELEASE");
  assert.equal(machine.step(confidentYes, 1_500, gestures).trigger, null);
  machine.step(rest, 1_600, gestures);
  machine.step(rest, 1_700, gestures);
  assert.equal(machine.step(rest, 1_800, gestures).state, "REST");
});

test("out-of-distribution input never becomes a candidate", () => {
  const machine = new IntentMachine(.7, 2);
  const output = machine.step({ ...confidentYes, inDistribution: false }, 0, gestures);
  assert.equal(output.state, "REST");
  assert.equal(output.trigger, null);
});

test("emergency policy uses its explicit longer dwell", () => {
  const machine = new IntentMachine(.7, 2);
  const emergency = { handPresent: true, gestureId: "emergency", confidence: .99, inDistribution: true };
  machine.step(emergency, 0, gestures);
  assert.equal(machine.step(emergency, 1_000, gestures).trigger, null);
  assert.equal(machine.step(emergency, 1_501, gestures).trigger?.risk, "emergency");
});

