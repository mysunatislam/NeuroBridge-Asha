from __future__ import annotations

import pytest

from fingerspeak_api.services.rag.engine import EmbeddedRAGRetriever


@pytest.fixture
def rag_retriever() -> EmbeddedRAGRetriever:
    return EmbeddedRAGRetriever()


def test_rag_seizure_triage_query(rag_retriever: EmbeddedRAGRetriever) -> None:
    results = rag_retriever.retrieve("What to do if patient is having a convulsion and choking?")
    assert len(results) > 0
    top = results[0]
    assert "seizure" in top.title.lower()
    assert top.category == "seizure_first_aid"
    # Accept any content from the seizure document
    seizure_terms = {"seizure", "convulsion", "airway", "recovery position", "emergency", "breathing", "jerking"}
    assert any(term in top.snippet.lower() for term in seizure_terms)


def test_rag_als_fatigue_pacing(rag_retriever: EmbeddedRAGRetriever) -> None:
    results = rag_retriever.retrieve("How to prevent fatigue during ALS micro-gesture calibration?")
    assert len(results) > 0
    top = results[0]
    assert "als" in top.title.lower() or "motor neuron" in top.title.lower()
    assert top.category == "als_mnd"


def test_rag_sci_autonomic_dysreflexia(rag_retriever: EmbeddedRAGRetriever) -> None:
    results = rag_retriever.retrieve("What is autonomic dysreflexia pounding headache in quadriplegia?")
    assert len(results) > 0
    top = results[0]
    assert "spinal cord" in top.title.lower()
    assert "dysreflexia" in top.snippet.lower()


def test_rag_device_operations_lighting(rag_retriever: EmbeddedRAGRetriever) -> None:
    results = rag_retriever.retrieve("How should I position the wheelchair camera and lighting?")
    assert len(results) > 0
    top = results[0]
    assert "wheelchair" in top.title.lower() or "camera" in top.title.lower()
    assert top.category == "device_operations"


def test_rag_bilingual_bangla(rag_retriever: EmbeddedRAGRetriever) -> None:
    results = rag_retriever.retrieve("রোগীর খিঁচুনি হলে প্রাথমিক করণীয় কী?")
    assert len(results) > 0
    top = results[0]
    assert top.category == "bilingual_guidance"


def test_rag_empty_query_returns_empty(rag_retriever: EmbeddedRAGRetriever) -> None:
    assert rag_retriever.retrieve("") == []
    assert rag_retriever.retrieve("   ") == []
    assert rag_retriever.retrieve("the a an and") == []


def test_rag_category_filter(rag_retriever: EmbeddedRAGRetriever) -> None:
    results = rag_retriever.retrieve("water", category="care_routine")
    for r in results:
        assert r.category == "care_routine"
