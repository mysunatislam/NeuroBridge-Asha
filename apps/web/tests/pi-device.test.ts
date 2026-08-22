import assert from "node:assert/strict";
import test from "node:test";
import {
  createCaptionCommand,
  createEmergencyDisplayCommand,
  createHeartbeatCommand,
  createPairingAuthentication,
  parsePairingAuthenticatedMessage,
  parsePiCommandResult,
  parsePiTelemetryMessage,
  PI_DEVICE_SUBPROTOCOL,
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
