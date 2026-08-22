# FingerSpeak API

FastAPI control plane for FingerSpeak. It stores user-approved configuration, session summaries,
derived reliability events, model metadata, and durable caregiver alerts. Gesture recognition and
speech remain on the user's device.

## Privacy and consent boundary

This service deliberately has **no endpoint for camera frames, video, audio, hand landmarks,
biometric templates, or raw calibration sequences**. Request models reject unknown fields, and an
HTTP middleware rejects image, video, multipart, and binary request bodies. The API accepts only:

- phrase/gesture vocabulary configured by the user;
- session and derived reliability metadata when analytics consent is enabled; an optional gesture
  reference must be a per-profile salted `g-<64 lowercase hex characters>` token;
- model-version metadata and an external artifact URI when model-sync consent is enabled; and
- an intentional caregiver-alert message when caregiver-alert consent is enabled.

Keep real-time inference, the confirmation state machine, and immediate speech on-device. Consent
flags are enforced on writes; changing a flag does not replace a real retention/deletion workflow.
Before production use, add jurisdiction-specific consent copy, deletion/export jobs, retention
policies, encryption/key management, threat modeling, and clinical/regulatory review.

## Local setup

Requirements: Python 3.12+ and PostgreSQL.

```powershell
cd E:\FingerSpeak\services\api
py -3.12 -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -e ".[dev]"
Copy-Item .env.example .env
alembic upgrade head
uvicorn fingerspeak_api.main:app --reload
```

For managed PostgreSQL, set the complete `FINGERSPEAK_DATABASE_URL`. Percent-encode reserved
characters in usernames and passwords before embedding them in a SQLAlchemy URL; a raw password
containing `@`, `:`, `/`, `%`, or `#` can otherwise be parsed as URL syntax.

Open `http://127.0.0.1:8000/docs`. Run checks with:

```powershell
pytest
ruff check .
python -m compileall -q src tests alembic
```

The application never creates production tables at startup; migrations are an explicit deployment
step. `/health/live` checks the process and `/health/ready` checks database connectivity.

## Verified gateway identity boundary

All resource routes require a gateway assertion in staging and production. A plain
`X-Actor-Subject` is rejected. The authentication gateway must first validate the user's OIDC/session
credential, remove all client-supplied `X-Actor-*` headers, and inject:

- `X-Actor-Subject`: the verified stable identity subject;
- `X-Actor-Timestamp`: current Unix time in whole seconds; and
- `X-Actor-Signature`: `v1=<lowercase HMAC-SHA256 hex digest>`.

The HMAC input is compact, sorted-key UTF-8 JSON with exactly these values:

```python
canonical = json.dumps(
    {
        "method": upstream_method.upper(),
        "path": application_path,
        "subject": verified_subject,
        "timestamp": unix_timestamp,
        "version": "v1",
    },
    ensure_ascii=False,
    separators=(",", ":"),
    sort_keys=True,
).encode("utf-8")
signature = "v1=" + hmac.new(shared_secret, canonical, hashlib.sha256).hexdigest()
```

`application_path` is the path as the FastAPI application sees it, without the query string. A
caregiver WebSocket upgrade is signed as method `GET` and path
`/v1/events/caregiver-alerts/ws`. The API binds assertions to subject, method, and path, accepts only
timestamps within `FINGERSPEAK_GATEWAY_SIGNATURE_TTL_SECONDS` of its own clock, and compares the
digest in constant time. Keep gateway and API clocks synchronized.

WebSocket upgrades must include an `Origin` that exactly matches one of the configured CORS origins;
missing and unlisted origins are rejected in every environment. Inbound WebSocket messages are text
JSON only and are capped by `FINGERSPEAK_WEBSOCKET_MAX_MESSAGE_BYTES` (4096 by default). Container
commands apply the same cap at Uvicorn's WebSocket transport boundary.

Set `FINGERSPEAK_GATEWAY_HMAC_SECRET` from a secret manager to at least 32 random bytes. Staging and
production fail at startup when it is absent or too short. The secret belongs only to the gateway and
API; never embed it in React, a mobile app, or any `NEXT_PUBLIC_*` value. Rotate it as a coordinated
gateway/API deployment, and use TLS plus a private gateway-to-API network.

The browser should send its normal gateway credential (for example, an OIDC session cookie or bearer
token), not any `X-Actor-*` assertion header. The API intentionally excludes those internal headers
from its CORS allow-list. Credentialed CORS is enabled for the explicit
`FINGERSPEAK_CORS_ORIGINS` list; startup validation rejects a wildcard origin whenever
`FINGERSPEAK_CORS_ALLOW_CREDENTIALS=true`. All `/v1` HTTP responses carry `Cache-Control: no-store,
private` and `Pragma: no-cache` so browsers and intermediaries do not retain profile or alert data.
In development/test, an unsigned subject may still be used directly, or a missing subject falls back
to `FINGERSPEAK_DEVELOPMENT_IDENTITY` only when
`FINGERSPEAK_ALLOW_DEVELOPMENT_IDENTITY=true`. Health routes remain unsigned.

Owners can mutate profiles, sessions, consent, caregiver grants, and model versions. An enabled
caregiver grant permits read access to that profile and acknowledgement of its alerts.

## Durable caregiver alerts

`POST /v1/events/caregiver-alerts` commits the event and alert to PostgreSQL before best-effort live
fan-out. Connect to:

```text
ws://127.0.0.1:8000/v1/events/caregiver-alerts/ws?profile_id=<uuid>
```

On connection the server first sends a database-backed snapshot of unresolved alerts, then live
created/acknowledged messages. Clients should reconnect and replay; WebSocket delivery itself is not
treated as acknowledgement. Snapshots and non-cursor REST reads select the newest bounded window and
then return it chronologically, so older alerts cannot hide a recent emergency. Alert ordering uses
server receive time; the device's `requested_at` remains the source event time only.
`client_event_id` makes retried writes idempotent.

Sockets are registered by profile and verified actor. Revoking a caregiver grant closes that
caregiver's sockets for the profile; setting `caregiver_alerts_consent=false` closes all sockets for
the profile. An in-flight authorization token closes the check/connect race, so a concurrent
revocation cannot register a stale socket.

The included fan-out registry is process-local. Durable replay prevents loss during disconnects,
but deployments with multiple API replicas must bridge committed alert IDs and authorization-
revocation messages through Redis Streams, PostgreSQL LISTEN/NOTIFY, or a managed pub/sub service so
every replica can wake or close its local sockets.

## Asha chat and wheelchair devices

`POST /v1/asha/chat` is an authenticated, text-only boundary with deterministic urgent handling and
an offline fallback. A server-only `OPENAI_API_KEY` enables the optional Responses API adapter;
`FINGERSPEAK_OPENAI_MODEL` defaults to `gpt-5.6-terra`. Setting
`FINGERSPEAK_OPENAI_VECTOR_STORE_ID` enables file search only for an owner-authorized profile and
filters files by that profile id. Requests use `store=false`, bounded time/output, and are not saved
by this service.

RAG documents must be uploaded through a separate, consented administration workflow and tagged
with a `profile_id` file attribute equal to the FingerSpeak profile UUID. This API intentionally has
no general document-upload endpoint. A file without that exact attribute cannot be selected by the
Asha retrieval plan, and the route verifies profile ownership before enabling the filter.

Owners register Raspberry Pi units through `/v1/devices`; the scoped bearer token is returned once
and only its SHA-256 digest is stored. The Pi WebSocket accepts strict text JSON `telemetry`,
`caption.ack`, and `ping` messages. Camera frames, audio, landmarks, binary frames, and query-string
credentials remain prohibited. Authorized caregivers may read latest device status and send
short-lived captions; only owners may provision or revoke devices. Device fan-out is process-local, so multi-replica deployment
requires shared pub/sub for caption delivery and revocation.

## Main routes

- `GET /health/live`, `GET /health/ready`
- `/v1/profiles` plus owner-managed caregiver grants
- `/v1/sessions` and `/v1/sessions/{id}/end`
- `/v1/events` for consented derived telemetry
- `/v1/events/caregiver-alerts` for durable alerts and acknowledgement
- `/v1/model-versions` for metadata-only model registry operations
- `POST /v1/asha/chat` for Asha text responses with a safe offline fallback
- `/v1/devices` plus the scoped Raspberry Pi WebSocket and caption queue

There is intentionally no inference or media-upload route.
Derived-event requests also reject phrase text/keys and cleartext gesture labels. Their optional
`gesture_key` is schema-limited to the opaque `^g-[0-9a-f]{64}$` token emitted by the web client.

## Container

Build from this directory:

```powershell
docker build -t fingerspeak-api .
docker run --rm -p 8000:8000 --env-file .env fingerspeak-api
```

Run `alembic upgrade head` as a separate release job before starting new application instances. The
container runs as a non-root user and exposes only the API process.
