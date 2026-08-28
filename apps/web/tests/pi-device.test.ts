import assert from "node:assert/strict";
import test from "node:test";
import {
  createCaptionCommand,
  createEmergencyDisplayCommand,
  createHeartbeatCommand,
  createPairingAuthentication,
  parsePairingAuthenticatedMessage,
  parsePiCommandResult,
  parsePiPatientIntentMessage,
  parsePiTelemetryMessage,
  PI_DEVICE_SUBPROTOCOL,
  PI_INTENT_COOLDOWN_MS,
  PiPatientIntentGate,
} from "../app/lib/pi-device";

test("phone commands match the edge v1 envelope", () => {
  const pairing = createPairingAuthentication(
    "pairing-code-with-enough-entropy",
    "fingerspeak-pi",
    "phone-1",
    "pairing_code",
    0,
  );
  assert.equal(PI_DEVICE_SUBPROTOCOL, "fingerspeak.device.v1");
  assert.equal(pairing.version, 1);
  assert.equal(pairing.type, "pairing.authenticate");
  assert.equal(pairing.device_id, "fingerspeak-pi");
  assert.deepEqual(pairing.payload, {
    credential_kind: "pairing_code",
    credential: "pairing-code-with-enough-entropy",
    phone_id: "phone-1",
  });
  assert.equal(createHeartbeatCommand("fingerspeak-pi", 1).type, "heartbeat");

  const caption = createCaptionCommand("আমি এখানে আছি", "fingerspeak-pi", 2, "bn-BD");
  assert.equal(caption.type, "caption.set");
  assert.deepEqual(caption.payload, { text: "আমি এখানে আছি", language: "bn-BD" });

  const emergency = createEmergencyDisplayCommand("I need help now", "fingerspeak-pi", 3, "en-US");
  assert.equal(emergency.type, "emergency.display");
  assert.equal(emergency.payload.text, "I need help now");
  assert.ok(Date.parse(String(emergency.payload.expires_at)) > Date.now());
});

test("Pi display delivery waits for a matching command result", () => {
  const acknowledged = parsePiCommandResult(JSON.stringify({
    version: 1,
    type: "command.ack",
    payload: {
      command_id: "11111111-1111-4111-8111-111111111111",
      command_type: "caption.set",
      accepted: true,
      duplicate: false,
      detail: "Display updated.",
    },
  }));
  assert.deepEqual(acknowledged, {
    commandId: "11111111-1111-4111-8111-111111111111",
    commandType: "caption.set",
    accepted: true,
    detail: "Display updated.",
  });

  const rejected = parsePiCommandResult(JSON.stringify({
    version: 1,
    type: "protocol.error",
    payload: {
      code: "invalid_message",
      detail: "Command rejected.",
      ref_message_id: "22222222-2222-4222-8222-222222222222",
    },
  }));
  assert.equal(rejected?.accepted, false);
  assert.equal(rejected?.commandId, "22222222-2222-4222-8222-222222222222");
  assert.equal(parsePiCommandResult('{"type":"command.ack","payload":{}}'), null);
});

test("pairing response rotates to the device credential", () => {
  const accepted = parsePairingAuthenticatedMessage(JSON.stringify({
    version: 1,
    type: "pairing.authenticated",
    payload: {
      device_credential: "rotated-device-credential",
      heartbeat_interval_seconds: 5,
    },
  }));
  assert.deepEqual(accepted, {
    deviceCredential: "rotated-device-credential",
    heartbeatIntervalSeconds: 5,
  });
  assert.equal(parsePairingAuthenticatedMessage('{"type":"pairing.accepted"}'), null);
});

test("edge status maps snake-case telemetry without inventing battery values", () => {
  const telemetry = parsePiTelemetryMessage(JSON.stringify({
    version: 1,
    type: "device.status",
    sent_at: "2026-08-22T06:00:00Z",
    payload: {
      phone_connected: true,
      display_connected: true,
      camera_status: "ready",
      tracking_status: "tracking",
      pi_battery_percent: null,
      wheelchair_battery_percent: 63,
    },
  }));
  assert.deepEqual(telemetry, {
    tracking: true,
    camera: "ready",
    phoneConnected: true,
    piPowerPercent: null,
    wheelchairBatteryPercent: 63,
    lastSeen: "2026-08-22T06:00:00Z",
  });
});

test("patient intent parser accepts only the strict media-free v1 envelope", () => {
  const value = patientIntentEnvelope();
  assert.deepEqual(parsePiPatientIntentMessage(JSON.stringify(value)), {
    messageId: value.message_id,
    deviceId: "fingerspeak-pi",
    sequence: 44,
    sentAt: "2026-08-22T06:00:01Z",
    intent: "look_right",
    confidence: 0.91,
    detectedAt: "2026-08-22T06:00:00.900Z",
  });

  assert.equal(parsePiPatientIntentMessage(JSON.stringify({ ...value, frame: "not allowed" })), null);
  assert.equal(parsePiPatientIntentMessage(JSON.stringify({ ...value, payload: { ...value.payload, phrase: "Injected phrase" } })), null);
  assert.equal(parsePiPatientIntentMessage(JSON.stringify({ ...value, payload: { ...value.payload, confidence: 1.1 } })), null);
  assert.equal(parsePiPatientIntentMessage(JSON.stringify({ ...value, sent_at: "2026-08-22 06:00:01" })), null);
});

test("patient intent gate rejects replay, flood, stale, and out-of-order events", () => {
  const now = Date.parse("2026-08-22T06:00:02Z");
  const first = parsePiPatientIntentMessage(JSON.stringify(patientIntentEnvelope()))!;
  const gate = new PiPatientIntentGate();
  assert.equal(gate.accept(first, now), true);
  assert.equal(gate.accept(first, now + PI_INTENT_COOLDOWN_MS + 1), false);

  const tooSoon = { ...first, messageId: "22222222-2222-4222-8222-222222222222", sequence: 45 };
  assert.equal(gate.accept(tooSoon, now + PI_INTENT_COOLDOWN_MS - 1), false);
  const later = { ...first, messageId: "33333333-3333-4333-8333-333333333333", sequence: 46 };
  assert.equal(gate.accept(later, now + PI_INTENT_COOLDOWN_MS + 1), true);
  const outOfOrder = { ...first, messageId: "44444444-4444-4444-8444-444444444444", sequence: 45 };
  assert.equal(gate.accept(outOfOrder, now + PI_INTENT_COOLDOWN_MS * 3), false);

  const stale = { ...first, messageId: "55555555-5555-4555-8555-555555555555", sequence: 47, sentAt: "2026-08-22T05:58:00Z", detectedAt: "2026-08-22T05:58:00Z" };
  assert.equal(gate.accept(stale, now + PI_INTENT_COOLDOWN_MS * 4), false);
});

function patientIntentEnvelope() {
  return {
    version: 1,
    message_id: "11111111-1111-4111-8111-111111111111",
    device_id: "fingerspeak-pi",
    type: "patient.intent",
    sent_at: "2026-08-22T06:00:01Z",
    sequence: 44,
    payload: { intent: "look_right", confidence: 0.91, detected_at: "2026-08-22T06:00:00.900Z" },
  };
}
