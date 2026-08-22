from __future__ import annotations

from datetime import datetime
from typing import Annotated, Literal, Self
from uuid import UUID

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, field_validator, model_validator

from fingerspeak_api.database import utcnow
from fingerspeak_api.models import AlertSeverity, AlertStatus, EventType, ModelStatus

ShortKey = Annotated[
    str,
    Field(min_length=1, max_length=80, pattern=r"^[A-Za-z0-9][A-Za-z0-9_.-]*$"),
]
OpaqueGestureKey = Annotated[
    str,
    Field(
        pattern=r"^g-[0-9a-f]{64}$",
        description="Per-profile salted opaque gesture token; never a semantic label.",
    ),
]


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class ORMModel(StrictModel):
    model_config = ConfigDict(extra="forbid", from_attributes=True)


class GestureDefinition(StrictModel):
    key: ShortKey
    label: Annotated[str, Field(min_length=1, max_length=80)]
    phrase: Annotated[str, Field(max_length=280)] = ""
    dwell_ms: Annotated[int, Field(ge=250, le=5_000)] = 650
    high_stakes: bool = False


class ProfileCreate(StrictModel):
    display_name: Annotated[str, Field(min_length=1, max_length=120)]
    locale: Annotated[str, Field(min_length=2, max_length=16)] = "en-US"
    consent_version: Annotated[str, Field(min_length=1, max_length=32)]
    consent_granted_at: AwareDatetime
    analytics_consent: bool = False
    caregiver_alerts_consent: bool = False
    model_sync_consent: bool = False
    vocabulary: Annotated[list[GestureDefinition], Field(max_length=64)] = Field(
        default_factory=list
    )

    @model_validator(mode="after")
    def vocabulary_keys_are_unique(self) -> Self:
        keys = [gesture.key for gesture in self.vocabulary]
        if len(keys) != len(set(keys)):
            raise ValueError("vocabulary gesture keys must be unique")
        return self


class ProfileUpdate(StrictModel):
    display_name: Annotated[str | None, Field(min_length=1, max_length=120)] = None
    locale: Annotated[str | None, Field(min_length=2, max_length=16)] = None
    consent_version: Annotated[str | None, Field(min_length=1, max_length=32)] = None
    consent_granted_at: AwareDatetime | None = None
    analytics_consent: bool | None = None
    caregiver_alerts_consent: bool | None = None
    model_sync_consent: bool | None = None
    vocabulary: Annotated[list[GestureDefinition] | None, Field(max_length=64)] = None

    @model_validator(mode="after")
    def vocabulary_keys_are_unique(self) -> Self:
        if self.vocabulary is not None:
            keys = [gesture.key for gesture in self.vocabulary]
            if len(keys) != len(set(keys)):
                raise ValueError("vocabulary gesture keys must be unique")
        return self


class ProfileRead(ORMModel):
    id: UUID
    owner_subject: str
    display_name: str
    locale: str
    consent_version: str
    consent_granted_at: datetime
    analytics_consent: bool
    caregiver_alerts_consent: bool
    model_sync_consent: bool
    vocabulary: list[GestureDefinition]
    created_at: datetime
    updated_at: datetime


class CaregiverGrantCreate(StrictModel):
    caregiver_subject: Annotated[str, Field(min_length=1, max_length=200)]


class CaregiverGrantRead(ORMModel):
    profile_id: UUID
    caregiver_subject: str
    enabled: bool
    created_at: datetime
    updated_at: datetime


class SessionCreate(StrictModel):
    profile_id: UUID
    client_session_id: UUID
    device_id: Annotated[str | None, Field(min_length=1, max_length=128)] = None
    client_version: Annotated[str, Field(min_length=1, max_length=64)]
    model_version_id: UUID | None = None
    inference_location: Literal["on_device"] = "on_device"
    started_at: AwareDatetime = Field(default_factory=utcnow)


class SessionEnd(StrictModel):
    ended_at: AwareDatetime = Field(default_factory=utcnow)


class SessionRead(ORMModel):
    id: UUID
    profile_id: UUID
    client_session_id: UUID
    device_id: str | None
    client_version: str
    model_version_id: UUID | None
    inference_location: Literal["on_device"]
    started_at: datetime
    ended_at: datetime | None
    created_at: datetime
    updated_at: datetime


class DerivedEventCreate(StrictModel):
    session_id: UUID
    client_event_id: UUID
    event_type: EventType
    occurred_at: AwareDatetime = Field(default_factory=utcnow)
    gesture_key: OpaqueGestureKey | None = None
    confidence: Annotated[float | None, Field(ge=0, le=1)] = None
    latency_ms: Annotated[int | None, Field(ge=0, le=120_000)] = None
    model_version_id: UUID | None = None

    @field_validator("event_type")
    @classmethod
    def caregiver_alert_uses_dedicated_schema(cls, value: EventType) -> EventType:
        if value is EventType.caregiver_alert:
            raise ValueError("use /events/caregiver-alerts for caregiver alerts")
        return value


class EventRead(ORMModel):
    id: UUID
    profile_id: UUID
    session_id: UUID
    client_event_id: UUID
    event_type: EventType
    occurred_at: datetime
    gesture_key: str | None
    confidence: float | None
    latency_ms: int | None
    model_version_id: UUID | None
    created_at: datetime


class CaregiverAlertCreate(StrictModel):
    profile_id: UUID
    session_id: UUID
    client_event_id: UUID
    severity: AlertSeverity
    message: Annotated[str, Field(min_length=1, max_length=500)]
    requested_at: AwareDatetime = Field(default_factory=utcnow)


class CaregiverAlertRead(ORMModel):
    id: UUID
    profile_id: UUID
    session_id: UUID
    source_event_id: UUID
    severity: AlertSeverity
    message: str
    status: AlertStatus
    created_at: datetime
    acknowledged_at: datetime | None
    acknowledged_by: str | None
    resolved_at: datetime | None


class AlertSocketMessage(StrictModel):
    type: Literal[
        "caregiver_alert.snapshot",
        "caregiver_alert.created",
        "caregiver_alert.acknowledged",
        "caregiver_alert.resolved",
    ]
    alert: CaregiverAlertRead | None = None
    alerts: list[CaregiverAlertRead] | None = None


class ModelMetrics(StrictModel):
    validation_accuracy: Annotated[float | None, Field(ge=0, le=1)] = None
    validation_scope: Literal["same_session", "held_out_session", "multi_participant"] | None = None
    validation_samples: Annotated[int | None, Field(ge=0)] = None
    false_activations_per_hour: Annotated[float | None, Field(ge=0)] = None
    median_activation_latency_ms: Annotated[int | None, Field(ge=0)] = None


class ModelVersionCreate(StrictModel):
    profile_id: UUID
    semantic_version: Annotated[str, Field(min_length=1, max_length=64)]
    framework: Annotated[str, Field(min_length=1, max_length=40)]
    runtime: Annotated[str, Field(min_length=1, max_length=40)]
    feature_schema_version: Annotated[str, Field(min_length=1, max_length=80)]
    artifact_uri: Annotated[str | None, Field(max_length=2_048)] = None
    artifact_sha256: Annotated[str | None, Field(pattern=r"^[a-fA-F0-9]{64}$")] = None
    metrics: ModelMetrics = Field(default_factory=ModelMetrics)
    status: Literal[ModelStatus.draft, ModelStatus.validated] = ModelStatus.draft

    @field_validator("artifact_uri")
    @classmethod
    def artifact_uri_is_remote_reference(cls, value: str | None) -> str | None:
        if value is not None and not value.startswith(("https://", "s3://", "gs://", "azure://")):
            raise ValueError("artifact_uri must use https, s3, gs, or azure scheme")
        return value


class ModelVersionRead(ORMModel):
    id: UUID
    profile_id: UUID
    semantic_version: str
    framework: str
    runtime: str
    feature_schema_version: str
    artifact_uri: str | None
    artifact_sha256: str | None
    metrics: ModelMetrics
    status: ModelStatus
    activated_at: datetime | None
    created_at: datetime
    updated_at: datetime


class AshaPatientContext(StrictModel):
    """Small, untrusted UI context. It is never treated as medical truth or instructions."""

    profile_id: UUID | None = None
    preferred_name: Annotated[str | None, Field(min_length=1, max_length=80)] = None
    care_mode: Literal["communication", "autism", "rehab", "continuous", "wellbeing"] | None = None
    current_activity: Annotated[str | None, Field(min_length=1, max_length=160)] = None
    wheelchair_status: Literal["unknown", "idle", "moving", "stopped", "needs_attention"] | None = (
        None
    )
    recent_summary: Annotated[str | None, Field(min_length=1, max_length=500)] = None
    trusted_contact_available: bool | None = None


class AshaChatRequest(StrictModel):
    message: Annotated[str, Field(min_length=1, max_length=1_500)]
    previous_response_id: Annotated[
        str | None,
        Field(min_length=6, max_length=200, pattern=r"^resp_[A-Za-z0-9_-]+$"),
    ] = None
    locale: Annotated[
        str | None,
        Field(min_length=2, max_length=16, pattern=r"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$"),
    ] = None
    patient_context: AshaPatientContext | None = None

    @field_validator("message")
    @classmethod
    def message_is_not_only_whitespace(cls, value: str) -> str:
        cleaned = value.strip()
        if not cleaned:
            raise ValueError("message must contain visible text")
        return cleaned


class AshaCitation(StrictModel):
    title: Annotated[str, Field(min_length=1, max_length=240)]
    source_id: Annotated[str | None, Field(min_length=1, max_length=240)] = None


class AshaChatResponse(StrictModel):
    reply: Annotated[str, Field(min_length=1, max_length=4_000)]
    mode: Literal["fallback", "llm", "safety"]
    previous_response_id: Annotated[str | None, Field(max_length=200)] = None
    citations: Annotated[list[AshaCitation], Field(max_length=12)] = Field(default_factory=list)
    urgent: bool = False


class RegisteredDeviceCreate(StrictModel):
    profile_id: UUID
    name: Annotated[str, Field(min_length=1, max_length=80)]
    kind: Literal["raspberry_pi"] = "raspberry_pi"


class DeviceStateRead(StrictModel):
    sequence: int
    observed_at: datetime
    last_seen_at: datetime
    pi_battery_percent: int | None
    wheelchair_battery_percent: int | None
    wheelchair_status: Literal["unknown", "idle", "moving", "stopped", "needs_attention"]
    camera_status: Literal["unknown", "off", "ready", "active", "error"]
    display_status: Literal["unknown", "off", "ready", "active", "error"]
    transport: Literal["unknown", "wifi", "usb", "ethernet"]


class RegisteredDeviceRead(StrictModel):
    id: UUID
    profile_id: UUID
    name: str
    kind: Literal["raspberry_pi"]
    enabled: bool
    online: bool
    last_state: DeviceStateRead | None = None
    created_at: datetime
    updated_at: datetime
    revoked_at: datetime | None


class RegisteredDeviceProvisioned(StrictModel):
    device: RegisteredDeviceRead
    token: Annotated[str, Field(min_length=32, max_length=160)]


class DeviceCaptionCreate(StrictModel):
    client_message_id: UUID
    text: Annotated[str, Field(min_length=1, max_length=500)]
    locale: Annotated[
        str,
        Field(min_length=2, max_length=16, pattern=r"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$"),
    ] = "en-US"
    ttl_seconds: Annotated[int | None, Field(ge=10, le=300)] = None

    @field_validator("text")
    @classmethod
    def caption_is_not_only_whitespace(cls, value: str) -> str:
        cleaned = value.strip()
        if not cleaned:
            raise ValueError("text must contain visible text")
        return cleaned


class DeviceCaptionRead(ORMModel):
    id: UUID
    device_id: UUID
    client_message_id: UUID
    text: str
    locale: str
    created_at: datetime
    expires_at: datetime
    delivered_at: datetime | None
    acknowledged_at: datetime | None


class DeviceTelemetryMessage(StrictModel):
    type: Literal["telemetry"]
    sequence: Annotated[int, Field(ge=0, le=9_223_372_036_854_775_807)]
    observed_at: AwareDatetime = Field(default_factory=utcnow)
    pi_battery_percent: Annotated[int | None, Field(ge=0, le=100)]
    wheelchair_battery_percent: Annotated[int | None, Field(ge=0, le=100)]
    wheelchair_status: Literal["unknown", "idle", "moving", "stopped", "needs_attention"]
    camera_status: Literal["unknown", "off", "ready", "active", "error"]
    display_status: Literal["unknown", "off", "ready", "active", "error"]
    transport: Literal["unknown", "wifi", "usb", "ethernet"] = "unknown"


class DeviceCaptionAckMessage(StrictModel):
    type: Literal["caption.ack"]
    caption_id: UUID


class DevicePingMessage(StrictModel):
    type: Literal["ping"]


class HealthRead(StrictModel):
    status: Literal["ok"]
    service: str
    version: str
