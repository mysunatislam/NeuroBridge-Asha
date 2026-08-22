import assert from "node:assert/strict";
import test from "node:test";
import {
  createCaptionCommand,
  createHeartbeatCommand,
  createPairingAuthentication,
  parsePairingAuthenticatedMessage,
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
