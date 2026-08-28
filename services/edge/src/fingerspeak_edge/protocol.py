from __future__ import annotations

import unicodedata
from datetime import datetime
from typing import Annotated, Literal
from uuid import UUID

from pydantic import (
    AwareDatetime,
    BaseModel,
    ConfigDict,
    Field,
    TypeAdapter,
    field_validator,
)

from fingerspeak_edge.adapters import CameraStatus, DisplayMode, TrackingStatus

PROTOCOL_VERSION = 1
MAX_CAPTION_CHARACTERS = 280
MAX_EMERGENCY_CHARACTERS = 500

DeviceId = Annotated[
    str,
    Field(min_length=1, max_length=80, pattern=r"^[A-Za-z0-9][A-Za-z0-9_.-]*$"),
]
PhoneId = Annotated[
    str,
    Field(min_length=1, max_length=80, pattern=r"^[A-Za-z0-9][A-Za-z0-9_.-]*$"),
]
LanguageTag = Annotated[
    str,
    Field(min_length=2, max_length=35, pattern=r"^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$"),
]
CorrelationId = Annotated[str, Field(min_length=1, max_length=120)]
PatientIntentName = Literal[
    "blink",
    "look_left",
    "look_right",
    "eyebrows_up",
    "mouth_open",
]


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class EmptyPayload(StrictModel):
    pass


def normalise_display_text(value: str, *, maximum: int) -> str:
    text = unicodedata.normalize("NFC", value).strip()
    if not text:
        raise ValueError("display text must not be blank")
    if len(text) > maximum:
        raise ValueError(f"display text must contain at most {maximum} Unicode characters")
    forbidden_bidi = {
        "\u202a",
        "\u202b",
        "\u202c",
        "\u202d",
        "\u202e",
        "\u2066",
        "\u2067",
        "\u2068",
        "\u2069",
    }
    for character in text:
        if character in forbidden_bidi:
            raise ValueError("display text contains a bidirectional override character")
        if unicodedata.category(character) in {"Cc", "Cs"} and character not in {"\n", "\t"}:
            raise ValueError("display text contains a control character")
    return text


class PairingAuthenticatePayload(StrictModel):
    credential_kind: Literal["pairing_code", "device_credential"]
    credential: Annotated[str, Field(min_length=16, max_length=256)]
    phone_id: PhoneId


class CaptionSetPayload(StrictModel):
    text: Annotated[str, Field(min_length=1, max_length=MAX_CAPTION_CHARACTERS)]
    language: LanguageTag = "en-US"
    correlation_id: CorrelationId | None = None
    expires_at: AwareDatetime | None = None

    @field_validator("text")
    @classmethod
    def text_is_safe_plain_unicode(cls, value: str) -> str:
        return normalise_display_text(value, maximum=MAX_CAPTION_CHARACTERS)


class EmergencyDisplayPayload(StrictModel):
    text: Annotated[str, Field(min_length=1, max_length=MAX_EMERGENCY_CHARACTERS)]
    language: LanguageTag = "en-US"
    alert_id: CorrelationId | None = None
    expires_at: AwareDatetime | None = None

    @field_validator("text")
    @classmethod
    def text_is_safe_plain_unicode(cls, value: str) -> str:
        return normalise_display_text(value, maximum=MAX_EMERGENCY_CHARACTERS)


class ClientEnvelope(StrictModel):
    version: Literal[1]
    message_id: UUID
    device_id: DeviceId
    sent_at: AwareDatetime
    sequence: Annotated[int, Field(ge=0)]


class PairingAuthenticate(ClientEnvelope):
    type: Literal["pairing.authenticate"]
    payload: PairingAuthenticatePayload


class Heartbeat(ClientEnvelope):
    type: Literal["heartbeat"]
    payload: EmptyPayload


class StatusGet(ClientEnvelope):
    type: Literal["status.get"]
    payload: EmptyPayload


class CaptionSet(ClientEnvelope):
    type: Literal["caption.set"]
    payload: CaptionSetPayload


class EmergencyDisplay(ClientEnvelope):
    type: Literal["emergency.display"]
    payload: EmergencyDisplayPayload


ClientMessage = Annotated[
    PairingAuthenticate | Heartbeat | StatusGet | CaptionSet | EmergencyDisplay,
    Field(discriminator="type"),
]
CLIENT_MESSAGE_ADAPTER = TypeAdapter(ClientMessage)


class ServerEnvelope(StrictModel):
    version: Literal[1] = PROTOCOL_VERSION
    message_id: UUID
    device_id: DeviceId
    sent_at: AwareDatetime
    sequence: Annotated[int, Field(ge=0)]


class PairingAuthenticatedPayload(StrictModel):
    connection_id: UUID
    phone_id: PhoneId
    device_credential: str | None = None
    heartbeat_interval_seconds: Annotated[float, Field(gt=0, le=300)]
    heartbeat_timeout_seconds: Annotated[float, Field(gt=0, le=900)]
    max_message_bytes: Annotated[int, Field(ge=512, le=65_536)]


class PairingAuthenticated(ServerEnvelope):
    type: Literal["pairing.authenticated"] = "pairing.authenticated"
    payload: PairingAuthenticatedPayload


class DeviceStatusPayload(StrictModel):
    phone_connected: bool
    display_connected: bool
    camera_status: CameraStatus
    tracking_status: TrackingStatus
    pi_battery_percent: Annotated[float | None, Field(ge=0, le=100)] = None
    wheelchair_battery_percent: Annotated[float | None, Field(ge=0, le=100)] = None
    active_display: DisplayMode | None = None
    display_revision: Annotated[int | None, Field(ge=1)] = None


class DeviceStatus(ServerEnvelope):
    type: Literal["device.status"] = "device.status"
    payload: DeviceStatusPayload


class CommandAckPayload(StrictModel):
    command_id: UUID
    command_type: Literal["heartbeat", "status.get", "caption.set", "emergency.display"]
    accepted: bool
    duplicate: bool = False
    detail: Annotated[str, Field(min_length=1, max_length=240)]
    display_revision: Annotated[int | None, Field(ge=1)] = None


class CommandAck(ServerEnvelope):
    type: Literal["command.ack"] = "command.ack"
    payload: CommandAckPayload


class ProtocolErrorPayload(StrictModel):
    code: Annotated[str, Field(min_length=1, max_length=64, pattern=r"^[a-z0-9_.-]+$")]
    detail: Annotated[str, Field(min_length=1, max_length=240)]
    ref_message_id: UUID | None = None


class ProtocolError(ServerEnvelope):
    type: Literal["protocol.error"] = "protocol.error"
    payload: ProtocolErrorPayload


class PatientIntentPayload(StrictModel):
    intent: PatientIntentName
    confidence: Annotated[float, Field(ge=0, le=1)]
    detected_at: AwareDatetime


class PatientIntent(ServerEnvelope):
    type: Literal["patient.intent"] = "patient.intent"
    payload: PatientIntentPayload


ServerMessage = PairingAuthenticated | DeviceStatus | CommandAck | ProtocolError | PatientIntent


def parse_client_message(raw: str) -> ClientMessage:
    return CLIENT_MESSAGE_ADAPTER.validate_json(raw)


def timestamp_is_aware(value: datetime) -> bool:
    return value.tzinfo is not None and value.utcoffset() is not None
