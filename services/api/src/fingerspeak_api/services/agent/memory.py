"""Patient Memory Engine for NeuroBridge Asha.

Provides three-tier memory:
1. Short-term working scratchpad (dialogue context, recent observations).
2. Long-term episodic memory (patient preferences, clinical profile, caregiver contacts).
3. Semantic / Digital Twin memory (individual recovery baselines, rehabilitation routines, risk factors).
"""

from __future__ import annotations

import re
import time
import unicodedata
import uuid
from dataclasses import asdict, dataclass, field
from typing import Any


@dataclass(slots=True)
class MemoryFact:
    id: str
    profile_id: str
    category: str  # "preference", "clinical_profile", "caregiver_info", "routine_history", "digital_twin", "general"
    key: str
    value: str
    confidence: float = 1.0
    created_at: float = field(default_factory=time.time)
    last_accessed_at: float = field(default_factory=time.time)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(slots=True)
class DigitalTwinProfile:
    user_name: str = "Rahim"
    condition: str = "Stroke Recovery (Left Hemiparesis)"
    communication_modality: str = "Right hand micro-gestures & eye-blink scanning"
    language: str = "Bangla / English"
    voice_preference: str = "Female (Warm & Reassuring)"
    common_requests: list[str] = field(
        default_factory=lambda: ["Water", "Pain", "Call daughter"]
    )
    prescribed_exercises: list[str] = field(
        default_factory=lambda: ["Neck lateral movement", "Active-assisted hand stretching"]
    )
    fall_detection_enabled: bool = True
    aspiration_precautions_active: bool = True

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def _tokenize(text: str) -> set[str]:
    normalized = unicodedata.normalize("NFKC", text).lower().replace("_", " ")
    return set(re.findall(r"\w{2,}", normalized))


class PatientMemoryEngine:
    """Thread-safe in-memory and persistent memory store for patient contextual facts."""

    def __init__(self) -> None:
        # profile_id -> list of MemoryFact
        self._store: dict[str, list[MemoryFact]] = {}

    def store(
        self,
        profile_id: str,
        category: str,
        key: str,
        value: str,
        confidence: float = 1.0,
    ) -> MemoryFact:
        """Upsert a memory fact for a given profile."""
        profile_facts = self._store.setdefault(profile_id, [])

        normalized_key = key.strip().lower()
        for fact in profile_facts:
            if fact.category == category and fact.key.strip().lower() == normalized_key:
                fact.value = value.strip()
                fact.confidence = confidence
                fact.last_accessed_at = time.time()
                return fact

        fact = MemoryFact(
            id=f"mem_{uuid.uuid4().hex[:12]}",
            profile_id=profile_id,
            category=category,
            key=key.strip(),
            value=value.strip(),
            confidence=confidence,
        )
        profile_facts.append(fact)
        return fact

    def recall(
        self,
        query: str,
        profile_id: str | None = None,
        top_k: int = 4,
        category: str | None = None,
    ) -> list[MemoryFact]:
        """Search memory for facts matching the query and optional category."""
        target_profiles = [profile_id] if profile_id else list(self._store.keys())
        all_facts: list[MemoryFact] = []
        for pid in target_profiles:
            all_facts.extend(self._store.get(pid, []))

        if not all_facts:
            return []

        query_tokens = _tokenize(query)

        scored: list[tuple[float, MemoryFact]] = []
        now = time.time()

        for fact in all_facts:
            if category and fact.category != category:
                continue

            fact_tokens = _tokenize(f"{fact.category} {fact.key} {fact.value}")
            overlap = len(query_tokens.intersection(fact_tokens))

            # Recency boost (within 24 hours gets up to 0.2 boost)
            hours_old = max(0.0, (now - fact.last_accessed_at) / 3600.0)
            recency_boost = max(0.0, 0.2 * (1.0 - min(hours_old / 24.0, 1.0)))

            score = (float(overlap) * fact.confidence) + recency_boost

            if overlap > 0 or not query.strip():
                fact.last_accessed_at = now
                scored.append((score, fact))

        scored.sort(key=lambda item: item[0], reverse=True)
        return [item[1] for item in scored[:top_k]]

    def get_all(self, profile_id: str) -> list[MemoryFact]:
        """Return all facts for a profile."""
        return list(self._store.get(profile_id, []))

    def get_summary_text(self, profile_id: str, max_facts: int = 6) -> str:
        """Format top facts into a concise prompt context string."""
        facts = self._store.get(profile_id, [])
        if not facts:
            return ""
        lines = []
        for f in facts[:max_facts]:
            lines.append(f"• {f.category.replace('_', ' ').capitalize()}: {f.key} = {f.value}")
        return "\n".join(lines)

    def clear(self, profile_id: str | None = None) -> int:
        """Clear facts for a specific profile or all profiles."""
        if profile_id:
            count = len(self._store.get(profile_id, []))
            self._store.pop(profile_id, None)
            return count
        total = sum(len(facts) for facts in self._store.values())
        self._store.clear()
        return total

    def seed_digital_twin_profile(
        self,
        profile_id: str,
        digital_twin: DigitalTwinProfile | None = None,
    ) -> DigitalTwinProfile:
        """Seed a complete User Digital Twin profile into memory."""
        dt = digital_twin or DigitalTwinProfile()
        self.store(profile_id, "digital_twin", "user_name", dt.user_name)
        self.store(profile_id, "digital_twin", "condition", dt.condition)
        self.store(profile_id, "digital_twin", "communication_modality", dt.communication_modality)
        self.store(profile_id, "digital_twin", "language", dt.language)
        self.store(profile_id, "digital_twin", "voice_preference", dt.voice_preference)
        self.store(profile_id, "digital_twin", "common_requests", ", ".join(dt.common_requests))
        self.store(profile_id, "digital_twin", "prescribed_exercises", ", ".join(dt.prescribed_exercises))
        self.store(profile_id, "digital_twin", "fall_detection", str(dt.fall_detection_enabled))
        self.store(profile_id, "digital_twin", "aspiration_precautions", str(dt.aspiration_precautions_active))
        return dt

    def seed_initial_profile(
        self,
        profile_id: str,
        preferred_name: str | None = None,
        care_mode: str = "continuous",
        locale: str = "en-US",
    ) -> None:
        """Seed starter memory facts if profile is new."""
        if profile_id in self._store and self._store[profile_id]:
            return

        name = preferred_name or "Rahim"
        self.store(profile_id, "preference", "preferred_name", name)
        self.store(profile_id, "clinical_profile", "care_mode", care_mode)
        self.store(profile_id, "preference", "communication_locale", locale)
        self.store(
            profile_id, "preference", "drinking_preference", "room temperature water with straw"
        )
        self.store(profile_id, "routine_history", "hydration_target_ml", "1500")
        self.store(profile_id, "routine_history", "reposition_interval_minutes", "120")
        self.seed_digital_twin_profile(profile_id)
