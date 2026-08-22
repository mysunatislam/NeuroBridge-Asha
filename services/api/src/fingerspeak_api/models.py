from __future__ import annotations

from datetime import datetime
from enum import StrEnum
from typing import Any
from uuid import UUID

from sqlalchemy import (
    JSON,
    BigInteger,
    Boolean,
    CheckConstraint,
    DateTime,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    Uuid,
)
from sqlalchemy import (
    Enum as SAEnum,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from fingerspeak_api.database import Base, TimestampMixin, UUIDPrimaryKeyMixin, utcnow

JSON_VALUE = JSON().with_variant(JSONB(), "postgresql")


class EventType(StrEnum):
    phrase_spoken = "phrase_spoken"
    false_activation = "false_activation"
    missed_gesture = "missed_gesture"
    inference_rejected = "inference_rejected"
    recognition_latency = "recognition_latency"
    caregiver_alert = "caregiver_alert"


class AlertSeverity(StrEnum):
    routine = "routine"
    urgent = "urgent"
    emergency = "emergency"


class AlertStatus(StrEnum):
    pending = "pending"
    acknowledged = "acknowledged"
    resolved = "resolved"


class ModelStatus(StrEnum):
    draft = "draft"
    validated = "validated"
    active = "active"
    retired = "retired"


class Profile(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "profiles"

    owner_subject: Mapped[str] = mapped_column(String(200), nullable=False, index=True)
    display_name: Mapped[str] = mapped_column(String(120), nullable=False)
    locale: Mapped[str] = mapped_column(String(16), nullable=False, default="en-US")
    consent_version: Mapped[str] = mapped_column(String(32), nullable=False)
    consent_granted_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    analytics_consent: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    caregiver_alerts_consent: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    model_sync_consent: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    vocabulary: Mapped[list[dict[str, Any]]] = mapped_column(
        JSON_VALUE, nullable=False, default=list
    )


class CaregiverGrant(TimestampMixin, Base):
    __tablename__ = "caregiver_grants"

    profile_id: Mapped[UUID] = mapped_column(
        Uuid(as_uuid=True), ForeignKey("profiles.id", ondelete="CASCADE"), primary_key=True
    )
    caregiver_subject: Mapped[str] = mapped_column(String(200), primary_key=True)
    enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)

    __table_args__ = (Index("ix_caregiver_grants_subject", "caregiver_subject", "enabled"),)


class ModelVersion(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "model_versions"

    profile_id: Mapped[UUID] = mapped_column(
        Uuid(as_uuid=True), ForeignKey("profiles.id", ondelete="CASCADE"), nullable=False
    )
    semantic_version: Mapped[str] = mapped_column(String(64), nullable=False)
    framework: Mapped[str] = mapped_column(String(40), nullable=False)
    runtime: Mapped[str] = mapped_column(String(40), nullable=False)
    feature_schema_version: Mapped[str] = mapped_column(String(80), nullable=False)
    artifact_uri: Mapped[str | None] = mapped_column(Text, nullable=True)
    artifact_sha256: Mapped[str | None] = mapped_column(String(64), nullable=True)
    metrics: Mapped[dict[str, Any]] = mapped_column(JSON_VALUE, nullable=False, default=dict)
    status: Mapped[ModelStatus] = mapped_column(
        SAEnum(
            ModelStatus,
            name="model_status",
            native_enum=False,
            create_constraint=True,
            validate_strings=True,
        ),
        nullable=False,
        default=ModelStatus.draft,
    )
    activated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    __table_args__ = (
        UniqueConstraint("profile_id", "semantic_version", name="uq_model_versions_profile_semver"),
        Index("ix_model_versions_profile_status", "profile_id", "status"),
    )


class SessionRecord(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "sessions"

    profile_id: Mapped[UUID] = mapped_column(
        Uuid(as_uuid=True), ForeignKey("profiles.id", ondelete="CASCADE"), nullable=False
    )
    client_session_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False)
    device_id: Mapped[str | None] = mapped_column(String(128), nullable=True)
    client_version: Mapped[str] = mapped_column(String(64), nullable=False)
    model_version_id: Mapped[UUID | None] = mapped_column(
        Uuid(as_uuid=True), ForeignKey("model_versions.id", ondelete="SET NULL"), nullable=True
    )
    inference_location: Mapped[str] = mapped_column(String(20), nullable=False, default="on_device")
    started_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    __table_args__ = (
        UniqueConstraint("profile_id", "client_session_id", name="uq_sessions_profile_client"),
        CheckConstraint("inference_location = 'on_device'", name="inference_location_on_device"),
        Index("ix_sessions_profile_started", "profile_id", "started_at"),
    )


class Event(UUIDPrimaryKeyMixin, Base):
    __tablename__ = "events"

    profile_id: Mapped[UUID] = mapped_column(
        Uuid(as_uuid=True), ForeignKey("profiles.id", ondelete="CASCADE"), nullable=False
    )
    session_id: Mapped[UUID] = mapped_column(
        Uuid(as_uuid=True), ForeignKey("sessions.id", ondelete="CASCADE"), nullable=False
    )
    client_event_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False)
    event_type: Mapped[EventType] = mapped_column(
        SAEnum(
            EventType,
            name="event_type",
            native_enum=False,
            create_constraint=True,
            validate_strings=True,
        ),
        nullable=False,
    )
    occurred_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    gesture_key: Mapped[str | None] = mapped_column(String(80), nullable=True)
    # Preserve compatibility with the already-issued initial migration without exposing or loading
    # this retired field. DerivedEventCreate forbids it and EventRead never serializes it.
    _legacy_phrase_key: Mapped[str | None] = mapped_column(
        "phrase_key", String(80), nullable=True, deferred=True
    )
    confidence: Mapped[float | None] = mapped_column(Float, nullable=True)
    latency_ms: Mapped[int | None] = mapped_column(Integer, nullable=True)
    model_version_id: Mapped[UUID | None] = mapped_column(
        Uuid(as_uuid=True), ForeignKey("model_versions.id", ondelete="SET NULL"), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )

    __table_args__ = (
        UniqueConstraint("session_id", "client_event_id", name="uq_events_session_client"),
        CheckConstraint(
            "confidence IS NULL OR (confidence >= 0 AND confidence <= 1)",
            name="confidence_range",
        ),
        CheckConstraint("latency_ms IS NULL OR latency_ms >= 0", name="latency_nonnegative"),
        Index("ix_events_session_occurred", "session_id", "occurred_at"),
        Index("ix_events_profile_type", "profile_id", "event_type"),
    )


class CaregiverAlert(UUIDPrimaryKeyMixin, Base):
    __tablename__ = "caregiver_alerts"

    profile_id: Mapped[UUID] = mapped_column(
        Uuid(as_uuid=True), ForeignKey("profiles.id", ondelete="CASCADE"), nullable=False
    )
    session_id: Mapped[UUID] = mapped_column(
        Uuid(as_uuid=True), ForeignKey("sessions.id", ondelete="CASCADE"), nullable=False
    )
    source_event_id: Mapped[UUID] = mapped_column(
        Uuid(as_uuid=True), ForeignKey("events.id", ondelete="CASCADE"), unique=True, nullable=False
    )
    severity: Mapped[AlertSeverity] = mapped_column(
        SAEnum(
            AlertSeverity,
            name="alert_severity",
            native_enum=False,
            create_constraint=True,
            validate_strings=True,
        ),
        nullable=False,
    )
    message: Mapped[str] = mapped_column(Text, nullable=False)
    status: Mapped[AlertStatus] = mapped_column(
        SAEnum(
            AlertStatus,
            name="alert_status",
            native_enum=False,
            create_constraint=True,
            validate_strings=True,
        ),
        nullable=False,
        default=AlertStatus.pending,
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )
    acknowledged_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    acknowledged_by: Mapped[str | None] = mapped_column(String(200), nullable=True)
    resolved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    __table_args__ = (
        Index("ix_caregiver_alerts_profile_status_created", "profile_id", "status", "created_at"),
    )


class RegisteredDevice(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "registered_devices"

    profile_id: Mapped[UUID] = mapped_column(
        Uuid(as_uuid=True), ForeignKey("profiles.id", ondelete="CASCADE"), nullable=False
    )
    name: Mapped[str] = mapped_column(String(80), nullable=False)
    kind: Mapped[str] = mapped_column(String(32), nullable=False, default="raspberry_pi")
    token_sha256: Mapped[str] = mapped_column(String(64), nullable=False, unique=True)
    enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    __table_args__ = (
        CheckConstraint("kind = 'raspberry_pi'", name="registered_device_kind"),
        Index("ix_registered_devices_profile_enabled", "profile_id", "enabled"),
    )


class DeviceState(Base):
    __tablename__ = "device_states"

    device_id: Mapped[UUID] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("registered_devices.id", ondelete="CASCADE"),
        primary_key=True,
    )
    sequence: Mapped[int] = mapped_column(BigInteger, nullable=False)
    observed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    pi_battery_percent: Mapped[int | None] = mapped_column(Integer, nullable=True)
    wheelchair_battery_percent: Mapped[int | None] = mapped_column(Integer, nullable=True)
    wheelchair_status: Mapped[str] = mapped_column(String(24), nullable=False)
    camera_status: Mapped[str] = mapped_column(String(16), nullable=False)
    display_status: Mapped[str] = mapped_column(String(16), nullable=False)
    transport: Mapped[str] = mapped_column(String(16), nullable=False)

    __table_args__ = (
        CheckConstraint("sequence >= 0", name="device_state_sequence_nonnegative"),
        CheckConstraint(
            "pi_battery_percent IS NULL OR (pi_battery_percent >= 0 AND pi_battery_percent <= 100)",
            name="device_state_pi_battery_range",
        ),
        CheckConstraint(
            "wheelchair_battery_percent IS NULL OR "
            "(wheelchair_battery_percent >= 0 AND wheelchair_battery_percent <= 100)",
            name="device_state_wheelchair_battery_range",
        ),
        CheckConstraint(
            "wheelchair_status IN ('unknown', 'idle', 'moving', 'stopped', 'needs_attention')",
            name="device_state_wheelchair_status",
        ),
        CheckConstraint(
            "camera_status IN ('unknown', 'off', 'ready', 'active', 'error')",
            name="device_state_camera_status",
        ),
        CheckConstraint(
            "display_status IN ('unknown', 'off', 'ready', 'active', 'error')",
            name="device_state_display_status",
        ),
        CheckConstraint(
            "transport IN ('unknown', 'wifi', 'usb', 'ethernet')",
            name="device_state_transport",
        ),
        Index("ix_device_states_last_seen", "last_seen_at"),
    )


class DeviceCaption(UUIDPrimaryKeyMixin, Base):
    __tablename__ = "device_captions"

    device_id: Mapped[UUID] = mapped_column(
        Uuid(as_uuid=True),
        ForeignKey("registered_devices.id", ondelete="CASCADE"),
        nullable=False,
    )
    client_message_id: Mapped[UUID] = mapped_column(Uuid(as_uuid=True), nullable=False)
    text: Mapped[str] = mapped_column(Text, nullable=False)
    locale: Mapped[str] = mapped_column(String(16), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=utcnow
    )
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    delivered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    acknowledged_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    __table_args__ = (
        UniqueConstraint("device_id", "client_message_id", name="uq_device_captions_device_client"),
        Index(
            "ix_device_captions_pending",
            "device_id",
            "acknowledged_at",
            "expires_at",
        ),
    )
