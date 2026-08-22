from __future__ import annotations

import json

import pytest
from pydantic import ValidationError

from fingerspeak_edge.protocol import CaptionSet, PairingAuthenticate, parse_client_message
from tests.helpers import client_message, pairing_message


def test_pairing_frame_is_strict_and_discriminated() -> None:
    parsed = parse_client_message(json.dumps(pairing_message()))

    assert isinstance(parsed, PairingAuthenticate)
    assert parsed.payload.phone_id == "patient-phone-1"

    bad = pairing_message()
    bad["unexpected"] = True
    with pytest.raises(ValidationError):
        parse_client_message(json.dumps(bad))


def test_caption_accepts_bangla_and_normalises_unicode() -> None:
    raw = client_message(
        "caption.set",
        {
            "text": "  আমি আপনার সাথে আছি।  ",
            "language": "bn-BD",
            "correlation_id": "asha-turn-1",
        },
    )

    parsed = parse_client_message(json.dumps(raw, ensure_ascii=False))

    assert isinstance(parsed, CaptionSet)
    assert parsed.payload.text == "আমি আপনার সাথে আছি।"


@pytest.mark.parametrize("text", ["", "   ", "hello\u0000world", "safe\u202etext", "x" * 281])
def test_caption_rejects_blank_control_spoofing_and_oversize_text(text: str) -> None:
    raw = client_message("caption.set", {"text": text, "language": "en-US"})

    with pytest.raises(ValidationError):
        parse_client_message(json.dumps(raw))


def test_unknown_or_motor_control_commands_are_not_in_the_protocol() -> None:
    for message_type in ("shell.execute", "wheelchair.move", "motor.stop"):
        with pytest.raises(ValidationError):
            parse_client_message(json.dumps(client_message(message_type, {})))
