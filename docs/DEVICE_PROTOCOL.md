# FingerSpeak local device protocol v1

The normative schema is `../contracts/device-link-v1.schema.json`. The endpoint is
`/v1/device/ws` with WebSocket subprotocol `fingerspeak.device.v1`. Frames are UTF-8 text JSON and
default to a 4096-byte maximum.

Every frame contains `version`, `message_id`, `device_id`, `type`, `sent_at`, `sequence`, and a
strict `payload`. Unknown message types and object fields are rejected. Timestamps outside the
configured clock-skew window are rejected.

## Authentication

Browser WebSockets cannot set an Authorization header, and credentials must not appear in query
strings. The server accepts the socket but emits no telemetry until the first bounded frame is:

```json
{
  "version": 1,
  "message_id": "11111111-1111-4111-8111-111111111111",
  "device_id": "fingerspeak-pi",
  "type": "pairing.authenticate",
  "sent_at": "2026-08-22T12:00:00Z",
  "sequence": 0,
  "payload": {
    "credential_kind": "pairing_code",
    "credential": "one-time-high-entropy-code",
    "phone_id": "patient-phone-1"
  }
}
```

A successful one-time code is immediately cleared and exchanged once for a longer
`device_credential` in `pairing.authenticated`. The phone must store that credential securely and
use `credential_kind: device_credential` on reconnect. The current prototype retains only its hash
in process memory, so restarting the edge service requires a new pairing ceremony. Production must
persist the credential hash in protected storage and provide explicit owner-controlled revocation.

## Client messages

- `heartbeat` with `{}` keeps phone presence fresh.
- `status.get` with `{}` requests a snapshot.
- `caption.set` accepts plain Unicode text up to 280 characters, language, optional correlation ID,
  and optional expiry.
- `emergency.display` accepts plain Unicode text up to 500 characters, language, optional alert ID,
  and optional expiry.

The implementation normalizes text to NFC and rejects blank text, unsafe control characters, and
bidirectional override controls. A display implementation must render with a text API, never HTML.

## Server messages

- `pairing.authenticated`
- `device.status`
- `patient.intent`
- `command.ack`
- `protocol.error`

Status always includes:

```json
{
  "phone_connected": true,
  "display_connected": true,
  "camera_status": "ready",
  "tracking_status": "tracking",
  "pi_battery_percent": null,
  "wheelchair_battery_percent": null
}
```

Battery `null` means unavailable and must never be displayed as zero. Presence becomes false after
the heartbeat timeout. Status snapshots are sent after authentication, periodically, and after
commands.

An authenticated phone may receive a `patient.intent` at any time, independently of client
commands:

```json
{
  "version": 1,
  "message_id": "22222222-2222-4222-8222-222222222222",
  "device_id": "fingerspeak-pi",
  "type": "patient.intent",
  "sent_at": "2026-08-22T12:00:01Z",
  "sequence": 12,
  "payload": {
    "intent": "blink",
    "confidence": 0.91,
    "detected_at": "2026-08-22T12:00:01Z"
  }
}
```

The only valid intent values are `blink`, `look_left`, `look_right`, `eyebrows_up`, and
`mouth_open`. The payload cannot contain frames, image URLs, landmarks, identity, emotion, pain, or
medical classifications. The edge applies calibration, debounce/hold, cooldown, and release before
broadcast. The phone deduplicates `message_id`; because gesture-to-phrase bindings remain local to
the phone, an emergency mapping must still use the phone's separate confirmation policy.

Display commands are idempotent by `message_id`. An exact retry returns a duplicate acknowledgement
without rendering twice; reusing the ID with different content is an error. An unexpired emergency
display blocks routine captions. Expired commands are acknowledged as rejected.

Close codes include `4401` authentication failure, `4403` origin rejection, `4406` missing
subprotocol, `1003` binary/non-text frame, and `1009` oversized frame.
