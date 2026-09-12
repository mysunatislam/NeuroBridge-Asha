"""Gemini as an optional reasoning assistant over *structured* events.

Boundary rules enforced here:

* input is the JSON produced by ``IntentPipeline.event_payload`` (state, gesture,
  confidence, history) - never frames, landmarks or feature vectors;
* every call has a deterministic offline fallback, so the assistant is never on the
  execution path of a command or alert;
* the API key is read from the environment or passed explicitly; nothing is cached
  on disk.

The REST endpoint is used directly through :mod:`urllib` to avoid an SDK dependency.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any

DEFAULT_MODEL = "gemini-2.5-flash"
ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"

SYSTEM_PROMPT = (
    "You are Asha, a calm caregiver assistant for a paralysed patient. You receive only "
    "structured events produced by an on-device intent recognition system. You never see "
    "video. Do not diagnose. Summarise what happened, say what the patient most likely "
    "needs, and suggest one concrete caregiver action. Keep answers under 80 words."
)

FORBIDDEN_KEYS = {
    "frame",
    "frames",
    "image",
    "images",
    "landmarks",
    "features",
    "sequence",
    "pixels",
}


@dataclass(slots=True)
class ReasoningRequest:
    task: str  # summarize | caregiver_message | patient_reply | long_term_patterns
    payload: dict[str, Any]
    caregiver_question: str | None = None

    def __post_init__(self) -> None:
        bad = FORBIDDEN_KEYS.intersection(_all_keys(self.payload))
        if bad:
            raise ValueError(
                f"raw sensor data must not be sent to the reasoning layer: {sorted(bad)}"
            )


def _all_keys(value: Any) -> set[str]:
    keys: set[str] = set()
    if isinstance(value, dict):
        for key, item in value.items():
            keys.add(str(key).lower())
            keys |= _all_keys(item)
    elif isinstance(value, list):
        for item in value:
            keys |= _all_keys(item)
    return keys


def offline_summary(request: ReasoningRequest) -> str:
    """Deterministic fallback used when no key/network is available."""

    payload = request.payload
    state = payload.get("patient_state", "idle")
    gesture = payload.get("gesture")
    confidence = payload.get("confidence")
    history = payload.get("patient_history") or ""
    conf_text = f" (confidence {confidence:.0%})" if isinstance(confidence, (int, float)) else ""
    if request.task == "long_term_patterns":
        events = payload.get("recent_events", [])
        executed = sum(1 for e in events if e.get("verdict", {}).get("decision") == "execute")
        alerts = sum(1 for e in events if e.get("verdict", {}).get("decision") == "alert")
        return (
            f"In the last {len(events)} decisions the patient completed {executed} commands and "
            f"{alerts} abnormal-movement alerts were raised. {history}".strip()
        )
    if (
        state.startswith("possible_abnormal")
        or state.startswith("possible_seizure")
        or state.startswith("possible_spasm")
    ):
        return (
            "Possible involuntary movement was detected. Commands are paused. "
            "Please check on the patient now."
        )
    if state == "awaiting_confirmation":
        return (
            f"The patient may have signalled '{_pretty(gesture)}'{conf_text}. "
            "Asha is asking them to confirm."
        )
    if state.startswith("command_"):
        return f"The patient signalled '{_pretty(gesture)}'{conf_text}. {history}".strip()
    if "help" in state:
        return (
            f"The patient appears to be asking for help via '{_pretty(gesture)}'{conf_text}. "
            f"Please respond now. {history}"
        ).strip()
    if gesture and state not in ("idle", "", None):
        return (
            f"The patient signalled '{_pretty(gesture)}'{conf_text} ({_pretty(state)}). {history}"
        ).strip()
    return "No new patient request. Monitoring continues offline."


def _pretty(value: Any) -> str:
    return str(value or "unknown").replace("_", " ")


@dataclass(slots=True)
class GeminiReasoner:
    api_key: str | None = None
    model: str = DEFAULT_MODEL
    timeout_s: float = 12.0
    enabled: bool = True
    last_error: str | None = field(default=None, init=False)

    def __post_init__(self) -> None:
        if self.api_key is None:
            self.api_key = os.environ.get("GEMINI_API_KEY") or None

    @property
    def available(self) -> bool:
        return bool(self.enabled and self.api_key)

    def reason(self, request: ReasoningRequest) -> tuple[str, bool]:
        """Return (text, used_gemini). Always succeeds thanks to the offline fallback."""

        if not self.available:
            return offline_summary(request), False
        try:
            return self._call(request), True
        except (urllib.error.URLError, TimeoutError, ValueError, KeyError) as exc:
            self.last_error = str(exc)
            return offline_summary(request), False

    def _call(self, request: ReasoningRequest) -> str:
        instruction = {
            "summarize": "Summarise the latest patient event for the care log.",
            "caregiver_message": (
                "Write a short message to the caregiver about what the patient needs."
            ),
            "patient_reply": "Write a gentle one-sentence reply to say to the patient.",
            "long_term_patterns": (
                "Describe patterns over the recent events and anything the care team should review."
            ),
        }.get(request.task, "Summarise the event.")
        parts = [
            {"text": instruction},
            {"text": "Structured event JSON:\n" + json.dumps(request.payload, indent=2)},
        ]
        if request.caregiver_question:
            parts.append({"text": "Caregiver question: " + request.caregiver_question})
        body = {
            "system_instruction": {"parts": [{"text": SYSTEM_PROMPT}]},
            "contents": [{"role": "user", "parts": parts}],
            "generationConfig": {"temperature": 0.3, "maxOutputTokens": 256},
        }
        url = ENDPOINT.format(model=self.model)
        data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=data,
            headers={"Content-Type": "application/json", "x-goog-api-key": str(self.api_key)},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=self.timeout_s) as response:  # noqa: S310
            decoded = json.loads(response.read().decode("utf-8"))
        candidates = decoded.get("candidates") or []
        if not candidates:
            raise ValueError("Gemini returned no candidates")
        text_parts = candidates[0].get("content", {}).get("parts", [])
        text = " ".join(part.get("text", "") for part in text_parts).strip()
        if not text:
            raise ValueError("Gemini returned an empty answer")
        return text
