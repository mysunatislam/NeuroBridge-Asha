"""Embedded RAG package for NeuroBridge Asha."""

from fingerspeak_api.services.rag.engine import (
    EmbeddedRAGRetriever,
    KnowledgeDocument,
    RetrievalResult,
)
from fingerspeak_api.services.rag.knowledge_base import CLINICAL_KNOWLEDGE_DOCUMENTS

__all__ = [
    "CLINICAL_KNOWLEDGE_DOCUMENTS",
    "EmbeddedRAGRetriever",
    "KnowledgeDocument",
    "RetrievalResult",
]
