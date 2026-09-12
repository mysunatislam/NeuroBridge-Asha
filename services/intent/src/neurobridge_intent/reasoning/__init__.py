"""Optional high-level reasoning layer (Phase 4). Never receives camera data."""

from .gemini import GeminiReasoner, ReasoningRequest, offline_summary

__all__ = ["GeminiReasoner", "ReasoningRequest", "offline_summary"]
