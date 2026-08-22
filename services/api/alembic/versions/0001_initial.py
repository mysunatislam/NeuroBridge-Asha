"""Create FingerSpeak control-plane tables.

Revision ID: 0001_initial
Revises: None
Create Date: 2026-08-15
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0001_initial"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "profiles",
        sa.Column("owner_subject", sa.String(length=200), nullable=False),
        sa.Column("display_name", sa.String(length=120), nullable=False),
        sa.Column("locale", sa.String(length=16), nullable=False),
        sa.Column("consent_version", sa.String(length=32), nullable=False),
        sa.Column("consent_granted_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("analytics_consent", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.Column(
            "caregiver_alerts_consent", sa.Boolean(), server_default=sa.false(), nullable=False
        ),
        sa.Column("model_sync_consent", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.Column(
            "vocabulary",
            postgresql.JSONB(astext_type=sa.Text()),
            server_default=sa.text("'[]'::jsonb"),
            nullable=False,
        ),
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.PrimaryKeyConstraint("id", name="pk_profiles"),
    )
    op.create_index("ix_profiles_owner_subject", "profiles", ["owner_subject"])

    op.create_table(
        "caregiver_grants",
        sa.Column("profile_id", sa.Uuid(), nullable=False),
        sa.Column("caregiver_subject", sa.String(length=200), nullable=False),
        sa.Column("enabled", sa.Boolean(), server_default=sa.true(), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.ForeignKeyConstraint(
            ["profile_id"],
            ["profiles.id"],
            name="fk_caregiver_grants_profile_id_profiles",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("profile_id", "caregiver_subject", name="pk_caregiver_grants"),
    )
    op.create_index(
        "ix_caregiver_grants_subject", "caregiver_grants", ["caregiver_subject", "enabled"]
    )

    op.create_table(
        "model_versions",
        sa.Column("profile_id", sa.Uuid(), nullable=False),
        sa.Column("semantic_version", sa.String(length=64), nullable=False),
        sa.Column("framework", sa.String(length=40), nullable=False),
        sa.Column("runtime", sa.String(length=40), nullable=False),
        sa.Column("feature_schema_version", sa.String(length=80), nullable=False),
        sa.Column("artifact_uri", sa.Text(), nullable=True),
        sa.Column("artifact_sha256", sa.String(length=64), nullable=True),
        sa.Column(
            "metrics",
            postgresql.JSONB(astext_type=sa.Text()),
            server_default=sa.text("'{}'::jsonb"),
            nullable=False,
        ),
        sa.Column("status", sa.String(length=9), server_default="draft", nullable=False),
        sa.Column("activated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.CheckConstraint(
            "status IN ('draft', 'validated', 'active', 'retired')",
            name=op.f("ck_model_versions_model_status"),
        ),
        sa.ForeignKeyConstraint(
            ["profile_id"],
            ["profiles.id"],
            name="fk_model_versions_profile_id_profiles",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_model_versions"),
        sa.UniqueConstraint(
            "profile_id", "semantic_version", name="uq_model_versions_profile_semver"
        ),
    )
    op.create_index("ix_model_versions_profile_status", "model_versions", ["profile_id", "status"])

    op.create_table(
        "sessions",
        sa.Column("profile_id", sa.Uuid(), nullable=False),
        sa.Column("client_session_id", sa.Uuid(), nullable=False),
        sa.Column("device_id", sa.String(length=128), nullable=True),
        sa.Column("client_version", sa.String(length=64), nullable=False),
        sa.Column("model_version_id", sa.Uuid(), nullable=True),
        sa.Column(
            "inference_location", sa.String(length=20), server_default="on_device", nullable=False
        ),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ended_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.CheckConstraint(
            "inference_location = 'on_device'",
            name=op.f("ck_sessions_inference_location_on_device"),
        ),
        sa.ForeignKeyConstraint(
            ["model_version_id"],
            ["model_versions.id"],
            name="fk_sessions_model_version_id_model_versions",
            ondelete="SET NULL",
        ),
        sa.ForeignKeyConstraint(
            ["profile_id"],
            ["profiles.id"],
            name="fk_sessions_profile_id_profiles",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_sessions"),
        sa.UniqueConstraint("profile_id", "client_session_id", name="uq_sessions_profile_client"),
    )
    op.create_index("ix_sessions_profile_started", "sessions", ["profile_id", "started_at"])

    op.create_table(
        "events",
        sa.Column("profile_id", sa.Uuid(), nullable=False),
        sa.Column("session_id", sa.Uuid(), nullable=False),
        sa.Column("client_event_id", sa.Uuid(), nullable=False),
        sa.Column("event_type", sa.String(length=19), nullable=False),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("gesture_key", sa.String(length=80), nullable=True),
        sa.Column("phrase_key", sa.String(length=80), nullable=True),
        sa.Column("confidence", sa.Float(), nullable=True),
        sa.Column("latency_ms", sa.Integer(), nullable=True),
        sa.Column("model_version_id", sa.Uuid(), nullable=True),
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.CheckConstraint(
            "event_type IN ('phrase_spoken', 'false_activation', 'missed_gesture', "
            "'inference_rejected', 'recognition_latency', 'caregiver_alert')",
            name=op.f("ck_events_event_type"),
        ),
        sa.CheckConstraint(
            "confidence IS NULL OR (confidence >= 0 AND confidence <= 1)",
            name=op.f("ck_events_confidence_range"),
        ),
        sa.CheckConstraint(
            "latency_ms IS NULL OR latency_ms >= 0",
            name=op.f("ck_events_latency_nonnegative"),
        ),
        sa.ForeignKeyConstraint(
            ["model_version_id"],
            ["model_versions.id"],
            name="fk_events_model_version_id_model_versions",
            ondelete="SET NULL",
        ),
        sa.ForeignKeyConstraint(
            ["profile_id"],
            ["profiles.id"],
            name="fk_events_profile_id_profiles",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["session_id"],
            ["sessions.id"],
            name="fk_events_session_id_sessions",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_events"),
        sa.UniqueConstraint("session_id", "client_event_id", name="uq_events_session_client"),
    )
    op.create_index("ix_events_profile_type", "events", ["profile_id", "event_type"])
    op.create_index("ix_events_session_occurred", "events", ["session_id", "occurred_at"])

    op.create_table(
        "caregiver_alerts",
        sa.Column("profile_id", sa.Uuid(), nullable=False),
        sa.Column("session_id", sa.Uuid(), nullable=False),
        sa.Column("source_event_id", sa.Uuid(), nullable=False),
        sa.Column("severity", sa.String(length=9), nullable=False),
        sa.Column("message", sa.Text(), nullable=False),
        sa.Column("status", sa.String(length=12), server_default="pending", nullable=False),
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column("acknowledged_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("acknowledged_by", sa.String(length=200), nullable=True),
        sa.Column("resolved_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            "severity IN ('routine', 'urgent', 'emergency')",
            name=op.f("ck_caregiver_alerts_alert_severity"),
        ),
        sa.CheckConstraint(
            "status IN ('pending', 'acknowledged', 'resolved')",
            name=op.f("ck_caregiver_alerts_alert_status"),
        ),
        sa.ForeignKeyConstraint(
            ["profile_id"],
            ["profiles.id"],
            name="fk_caregiver_alerts_profile_id_profiles",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["session_id"],
            ["sessions.id"],
            name="fk_caregiver_alerts_session_id_sessions",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["source_event_id"],
            ["events.id"],
            name="fk_caregiver_alerts_source_event_id_events",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name="pk_caregiver_alerts"),
        sa.UniqueConstraint("source_event_id", name="uq_caregiver_alerts_source_event_id"),
    )
    op.create_index(
        "ix_caregiver_alerts_profile_status_created",
        "caregiver_alerts",
        ["profile_id", "status", "created_at"],
    )


def downgrade() -> None:
    op.drop_index("ix_caregiver_alerts_profile_status_created", table_name="caregiver_alerts")
    op.drop_table("caregiver_alerts")
    op.drop_index("ix_events_session_occurred", table_name="events")
    op.drop_index("ix_events_profile_type", table_name="events")
    op.drop_table("events")
    op.drop_index("ix_sessions_profile_started", table_name="sessions")
    op.drop_table("sessions")
    op.drop_index("ix_model_versions_profile_status", table_name="model_versions")
    op.drop_table("model_versions")
    op.drop_index("ix_caregiver_grants_subject", table_name="caregiver_grants")
    op.drop_table("caregiver_grants")
    op.drop_index("ix_profiles_owner_subject", table_name="profiles")
    op.drop_table("profiles")
