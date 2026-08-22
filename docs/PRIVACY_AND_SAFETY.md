# Privacy and safety boundary

FingerSpeak is a portfolio-grade assistive communication prototype, not a validated medical device
or emergency service.

## Data that stays on the device

- camera frames and video;
- hand landmarks and feature vectors;
- raw calibration sequences;
- the active personalized edge model; and
- speech text and audio generation state; speech is attempted only with a browser voice marked
  `localService`.

Profiles and calibration samples are stored in IndexedDB. JSON profile exports contain sensitive
movement and phrase data and are **not encrypted**; the UI labels this at export time.

## Data that can leave the device

Nothing is synced by default. Separate controls enable derived activity events and caregiver alerts.
Derived activity contains a per-profile salted gesture token and timestamp, not a semantic label,
profile name, phrase, or raw motion. An alert may include the confirmed request text because its
purpose is to convey that request to an authorized caregiver; the caregiver-alert control states
this separately. The API rejects phrase fields and accepts a gesture reference only in the opaque
`^g-[0-9a-f]{64}$` form. Events are added to the retry outbox only when the relevant consent is active.
Withdrawal is persisted and retried, disallowed queued categories are purged, and unsent alerts
expire after two minutes so a stale urgent request is not delivered later as if it were current.

Consent is local user/device state. File import resets all network-sharing controls to off; consent
flags embedded in another person's JSON file are never adopted.

## Safety behavior

- Unrecognized movement is rejected rather than forced into the nearest class.
- A gesture must remain stable for its explicit per-intent dwell time.
- Emergency intent has a longer dwell and the touch fallback uses two-step confirmation.
- After a trigger, Rest or no hand must be observed for several ticks before retriggering.
- Local speech is started before any optional network request; if no verified local voice exists,
  the caption remains visible and the app tells the user to use backup AAC.
- Voice failure is shown visibly and does not imply that speech succeeded.
- The camera has an explicit Stop action and every media track stops on view change or unmount.
- WebSocket delivery is convenience notification, not guaranteed emergency delivery.

Before clinical use, add target-population validation, accessibility testing with switch users,
formal risk management, data-retention/export/delete workflows, encryption key management, signed
model updates, operational monitoring, backup channels, and the required regulatory process.
