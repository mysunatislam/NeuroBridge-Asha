"""FingerSpeak / NeuroBridge Asha - Flask RESTful Backend API.

Developed for Round 2: Backend & API Integration.
Provides RESTful endpoints for Profile Management, Session Tracking,
Consent Guards, Caregiver Alerts, and Outbox Event Ingestion.
"""

from __future__ import annotations

import os
import uuid
from datetime import datetime, timezone
from typing import Any

from flask import Flask, jsonify, request
from flask_cors import CORS

app = Flask(__name__)
# Enable Cross-Origin Resource Sharing (CORS) for Vue.js frontend running on Vite (e.g. port 5173 / 4173)
CORS(
    app,
    resources={r"/v1/*": {"origins": "*"}},
    supports_credentials=True,
    allow_headers=["Content-Type", "Authorization"],
    methods=["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
)

# In-memory mock database (or SQLite backing) for demonstration & unit testing
PROFILES: dict[str, dict[str, Any]] = {}
SESSIONS: dict[str, dict[str, Any]] = {}
ALERTS: dict[str, dict[str, Any]] = {}
EVENTS: list[dict[str, Any]] = []


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


# -----------------------------------------------------------------------------
# System & Health Check Endpoints
# -----------------------------------------------------------------------------
@app.route("/health", methods=["GET"])
@app.route("/v1/health", methods=["GET"])
def health_check():
    """Return backend health and readiness status."""
    return (
        jsonify(
            {
                "status": "healthy",
                "service": "FingerSpeak Flask REST Backend",
                "version": "2.0.0",
                "timestamp": utc_now_iso(),
            }
        ),
        200,
    )


# -----------------------------------------------------------------------------
# Profile Resource Endpoints
# -----------------------------------------------------------------------------
@app.route("/v1/profiles", methods=["POST"])
def create_profile():
    """Create a new patient or user profile with privacy/consent settings."""
    payload = request.get_json(silent=True) or {}

    profile_id = str(uuid.uuid4())
    profile_data = {
        "id": profile_id,
        "display_name": payload.get("display_name", "FingerSpeak Profile"),
        "locale": payload.get("locale", "en-US"),
        "consent_version": payload.get("consent_version", "prototype-v1"),
        "consent_granted_at": payload.get("consent_granted_at", utc_now_iso()),
        "analytics_consent": bool(payload.get("analytics_consent", False)),
        "caregiver_alerts_consent": bool(
            payload.get("caregiver_alerts_consent", True)
        ),
        "model_sync_consent": bool(payload.get("model_sync_consent", False)),
        "vocabulary": payload.get("vocabulary", []),
        "created_at": utc_now_iso(),
        "updated_at": utc_now_iso(),
    }
    PROFILES[profile_id] = profile_data
    return jsonify({"id": profile_id, "profile": profile_data}), 201


@app.route("/v1/profiles/<profile_id>", methods=["GET"])
def get_profile(profile_id: str):
    """Fetch existing profile details by ID."""
    profile = PROFILES.get(profile_id)
    if not profile:
        return (
            jsonify(
                {
                    "error": "ProfileNotFound",
                    "message": f"Profile {profile_id} does not exist.",
                }
            ),
            404,
        )
    return jsonify(profile), 200


@app.route("/v1/profiles/<profile_id>", methods=["PATCH"])
def update_profile_consent(profile_id: str):
    """Partially update profile consent or configuration."""
    profile = PROFILES.get(profile_id)
    if not profile:
        return (
            jsonify(
                {
                    "error": "ProfileNotFound",
                    "message": f"Profile {profile_id} not found.",
                }
            ),
            404,
        )

    payload = request.get_json(silent=True) or {}
    for key in (
        "analytics_consent",
        "caregiver_alerts_consent",
        "model_sync_consent",
        "display_name",
        "vocabulary",
    ):
        if key in payload:
            profile[key] = payload[key]

    profile["updated_at"] = utc_now_iso()
    return jsonify(profile), 200


# -----------------------------------------------------------------------------
# Session Resource Endpoints
# -----------------------------------------------------------------------------
@app.route("/v1/sessions", methods=["POST"])
def start_session():
    """Start an active telemetry and communication session for a profile."""
    payload = request.get_json(silent=True) or {}
    profile_id = payload.get("profile_id")
    if not profile_id or profile_id not in PROFILES:
        return (
            jsonify(
                {
                    "error": "InvalidProfileId",
                    "message": "Valid profile_id is required.",
                }
            ),
            400,
        )

    session_id = str(uuid.uuid4())
    session_data = {
        "id": session_id,
        "profile_id": profile_id,
        "client_session_id": payload.get("client_session_id", str(uuid.uuid4())),
        "device_id": payload.get("device_id", "browser-device"),
        "client_version": payload.get("client_version", "vue-web-2.0.0"),
        "inference_location": payload.get("inference_location", "on_device"),
        "started_at": payload.get("started_at", utc_now_iso()),
        "status": "active",
    }
    SESSIONS[session_id] = session_data
    return jsonify({"id": session_id, "session": session_data}), 201


# -----------------------------------------------------------------------------
# Event & Outbox Ingestion Endpoints
# -----------------------------------------------------------------------------
@app.route("/v1/events/caregiver-alerts", methods=["POST"])
def create_caregiver_alert_event():
    """Ingest an urgent or emergency caregiver alert from the frontend outbox."""
    payload = request.get_json(silent=True) or {}
    required_fields = ["profile_id", "session_id", "message"]
    missing = [field for field in required_fields if field not in payload]
    if missing:
        return (
            jsonify(
                {
                    "error": "ValidationFailed",
                    "message": f"Missing required fields: {', '.join(missing)}",
                }
            ),
            422,
        )

    alert_id = str(uuid.uuid4())
    alert = {
        "id": alert_id,
        "profile_id": payload["profile_id"],
        "session_id": payload["session_id"],
        "source_event_id": payload.get("client_event_id", alert_id),
        "severity": payload.get("severity", "routine"),
        "message": payload["message"],
        "status": "pending",
        "created_at": payload.get("requested_at", utc_now_iso()),
        "acknowledged_at": None,
        "acknowledged_by": None,
        "resolved_at": None,
    }
    ALERTS[alert_id] = alert
    EVENTS.append(
        {"type": "caregiver_alert", "alert_id": alert_id, "data": alert}
    )

    return jsonify({"id": alert_id, "alert": alert, "status": "recorded"}), 201


@app.route("/v1/events/analytics", methods=["POST"])
def record_analytics_event():
    """Record privacy-preserving client metrics if consent is granted."""
    payload = request.get_json(silent=True) or {}
    profile_id = payload.get("profile_id")

    profile = PROFILES.get(profile_id)
    if profile and not profile.get("analytics_consent", False):
        return (
            jsonify(
                {
                    "status": "discarded",
                    "reason": "analytics_consent_not_granted",
                }
            ),
            200,
        )

    event_record = {
        "id": str(uuid.uuid4()),
        "profile_id": profile_id,
        "event_type": payload.get("event_type", "metric"),
        "timestamp": utc_now_iso(),
        "payload": payload.get("payload", {}),
    }
    EVENTS.append(event_record)
    return jsonify({"status": "accepted", "id": event_record["id"]}), 201


# -----------------------------------------------------------------------------
# Caregiver Alerts Feed & Resolution Endpoints
# -----------------------------------------------------------------------------
@app.route("/v1/alerts", methods=["GET"])
def list_alerts():
    """Retrieve list of caregiver alerts, optionally filtered by profile_id."""
    profile_id = request.args.get("profile_id")
    alerts_list = list(ALERTS.values())
    if profile_id:
        alerts_list = [a for a in alerts_list if a["profile_id"] == profile_id]

    alerts_list.sort(key=lambda a: a["created_at"], reverse=True)
    return jsonify(alerts_list), 200


@app.route("/v1/alerts/<alert_id>", methods=["PATCH"])
def update_alert_status(alert_id: str):
    """Acknowledge or resolve an alert."""
    alert = ALERTS.get(alert_id)
    if not alert:
        return (
            jsonify(
                {
                    "error": "AlertNotFound",
                    "message": f"Alert {alert_id} not found.",
                }
            ),
            404,
        )

    payload = request.get_json(silent=True) or {}
    new_status = payload.get("status")
    if new_status in ("acknowledged", "resolved", "pending"):
        alert["status"] = new_status
        if new_status == "acknowledged":
            alert["acknowledged_at"] = utc_now_iso()
            alert["acknowledged_by"] = payload.get(
                "acknowledged_by", "caregiver"
            )
        elif new_status == "resolved":
            alert["resolved_at"] = utc_now_iso()

    return jsonify(alert), 200


# -----------------------------------------------------------------------------
# Global Error Handlers (REST Standards)
# -----------------------------------------------------------------------------
@app.errorhandler(404)
def not_found(_):
    return (
        jsonify(
            {
                "error": "NotFound",
                "message": "The requested endpoint does not exist.",
            }
        ),
        404,
    )


@app.errorhandler(405)
def method_not_allowed(_):
    return (
        jsonify(
            {
                "error": "MethodNotAllowed",
                "message": "HTTP method not allowed for this endpoint.",
            }
        ),
        405,
    )


@app.errorhandler(500)
def internal_server_error(error):
    return (
        jsonify(
            {
                "error": "InternalServerError",
                "message": "An unexpected server error occurred.",
            }
        ),
        500,
    )


if __name__ == "__main__":
    port = int(os.getenv("PORT", 8000))
    print(f"[*] Starting FingerSpeak Flask REST API on http://0.0.0.0:{port}")
    app.run(host="0.0.0.0", port=port, debug=True)
