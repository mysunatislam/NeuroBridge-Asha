"""Add registered Pi devices, latest state, and short-lived captions.

Revision ID: 0002_registered_devices
Revises: 0001_initial
Create Date: 2026-08-22
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0002_registered_devices"
down_revision: str | None = "0001_initial"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "registered_devices",
        sa.Column("profile_id", sa.Uuid(), nullable=False),
        sa.Column("name", sa.String(length=80), nullable=False),
        sa.Column("kind", sa.String(length=32), server_default="raspberry_pi", nullable=False),
        sa.Column("token_sha256", sa.String(length=64), nullable=False),
        sa.Column("enabled", sa.Boolean(), server_default=sa.true(), nullable=False),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.CheckConstraint(
            "kind = 'raspberry_pi'", name=op.f("ck_registered_devices_registered_device_kind")
        ),
        sa.ForeignKeyConstraint(
            ["profile_id"],
            ["profiles.id"],
            name=op.f("fk_registered_devices_profile_id_profiles"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_registered_devices")),
        sa.UniqueConstraint("token_sha256", name=op.f("uq_registered_devices_token_sha256")),
    )
    op.create_index(
        "ix_registered_devices_profile_enabled",
        "registered_devices",
        ["profile_id", "enabled"],
    )

    op.create_table(
        "device_states",
        sa.Column("device_id", sa.Uuid(), nullable=False),
        sa.Column("sequence", sa.BigInteger(), nullable=False),
        sa.Column("observed_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("pi_battery_percent", sa.Integer(), nullable=True),
        sa.Column("wheelchair_battery_percent", sa.Integer(), nullable=True),
        sa.Column("wheelchair_status", sa.String(length=24), nullable=False),
        sa.Column("camera_status", sa.String(length=16), nullable=False),
        sa.Column("display_status", sa.String(length=16), nullable=False),
        sa.Column("transport", sa.String(length=16), nullable=False),
        sa.CheckConstraint(
            "sequence >= 0", name=op.f("ck_device_states_device_state_sequence_nonnegative")
        ),
        sa.CheckConstraint(
            "pi_battery_percent IS NULL OR (pi_battery_percent >= 0 AND pi_battery_percent <= 100)",
            name=op.f("ck_device_states_device_state_pi_battery_range"),
        ),
        sa.CheckConstraint(
            "wheelchair_battery_percent IS NULL OR "
            "(wheelchair_battery_percent >= 0 AND wheelchair_battery_percent <= 100)",
            name=op.f("ck_device_states_device_state_wheelchair_battery_range"),
        ),
        sa.CheckConstraint(
            "wheelchair_status IN ('unknown', 'idle', 'moving', 'stopped', 'needs_attention')",
            name=op.f("ck_device_states_device_state_wheelchair_status"),
        ),
        sa.CheckConstraint(
            "camera_status IN ('unknown', 'off', 'ready', 'active', 'error')",
            name=op.f("ck_device_states_device_state_camera_status"),
        ),
        sa.CheckConstraint(
            "display_status IN ('unknown', 'off', 'ready', 'active', 'error')",
            name=op.f("ck_device_states_device_state_display_status"),
        ),
        sa.CheckConstraint(
            "transport IN ('unknown', 'wifi', 'usb', 'ethernet')",
            name=op.f("ck_device_states_device_state_transport"),
        ),
        sa.ForeignKeyConstraint(
            ["device_id"],
            ["registered_devices.id"],
            name=op.f("fk_device_states_device_id_registered_devices"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("device_id", name=op.f("pk_device_states")),
    )
    op.create_index("ix_device_states_last_seen", "device_states", ["last_seen_at"])

    op.create_table(
        "device_captions",
        sa.Column("device_id", sa.Uuid(), nullable=False),
        sa.Column("client_message_id", sa.Uuid(), nullable=False),
        sa.Column("text", sa.Text(), nullable=False),
        sa.Column("locale", sa.String(length=16), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("delivered_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("acknowledged_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.ForeignKeyConstraint(
            ["device_id"],
            ["registered_devices.id"],
            name=op.f("fk_device_captions_device_id_registered_devices"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_device_captions")),
        sa.UniqueConstraint(
            "device_id", "client_message_id", name="uq_device_captions_device_client"
        ),
    )
    op.create_index(
        "ix_device_captions_pending",
        "device_captions",
        ["device_id", "acknowledged_at", "expires_at"],
    )


def downgrade() -> None:
    op.drop_index("ix_device_captions_pending", table_name="device_captions")
    op.drop_table("device_captions")
    op.drop_index("ix_device_states_last_seen", table_name="device_states")
    op.drop_table("device_states")
    op.drop_index("ix_registered_devices_profile_enabled", table_name="registered_devices")
    op.drop_table("registered_devices")
