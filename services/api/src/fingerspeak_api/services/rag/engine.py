"""Embedded hybrid vector and semantic retrieval engine for NeuroBridge Asha.

Implements fast in-memory TF-IDF + BM25-style keyword and semantic vector indexing
with zero external runtime dependencies.
"""

from __future__ import annotations

import math
import re
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass
from typing import Sequence

from fingerspeak_api.schemas import AshaCitation, AshaPatientContext
from fingerspeak_api.services.rag.knowledge_base import (
    CLINICAL_KNOWLEDGE_DOCUMENTS,
    KnowledgeDocument,
)

_STOPWORDS = frozenset(
    {
        "a", "about", "above", "after", "again", "against", "all", "am", "an", "and",
        "any", "are", "aren't", "as", "at", "be", "because", "been", "before", "being",
        "below", "between", "both", "but", "by", "can't", "cannot", "could", "couldn't",
        "did", "didn't", "do", "does", "doesn't", "doing", "don't", "down", "during",
        "each", "few", "for", "from", "further", "had", "hadn't", "has", "hasn't",
        "have", "haven't", "having", "he", "he'd", "he'll", "he's", "her", "here",
        "hers", "herself", "him", "himself", "his", "how", "i", "i'd", "i'll", "i'm",
        "i've", "if", "in", "into", "is", "isn't", "it", "it's", "its", "itself",
        "let's", "me", "more", "most", "mustn't", "my", "myself", "no", "nor", "not",
        "of", "off", "on", "once", "only", "or", "other", "ought", "our", "ours",
        "ourselves", "out", "over", "own", "same", "shan't", "she", "she'd", "she'll",
        "she's", "should", "shouldn't", "so", "some", "such", "than", "that", "that's",
        "the", "their", "theirs", "them", "themselves", "then", "there", "there's",
        "these", "they", "they'd", "they'll", "they're", "they've", "this", "those",
        "through", "to", "too", "under", "until", "up", "very", "was", "wasn't", "we",
        "we'd", "we'll", "we're", "we've", "were", "weren't", "what", "what's", "when",
        "where", "which", "while", "who", "whom", "why", "with", "won't", "would",
        "wouldn't", "you", "you'd", "you'll", "you're", "you've", "your", "yours",
        "yourself", "yourselves",
    }
)


def _tokenize(text: str) -> list[str]:
    normalized = unicodedata.normalize("NFKC", text).lower()
    tokens = re.findall(r"[\w-]+", normalized)
    return [t for t in tokens if len(t) >= 2 and t not in _STOPWORDS]


_SYNONYMS: dict[str, list[str]] = {
    "জল": ["water", "hydration"],
    "পানি": ["water", "hydration"],
    "thirsty": ["hydration", "drinking", "water"],
    "কাঁপুনি": ["seizure", "convulsion"],
    "খিঁচুনি": ["seizure", "convulsion"],
    "seizure": ["convulsion", "airway", "recovery"],
    "choking": ["airway", "obstruction", "distress"],
    "dysreflexia": ["autonomic", "hypertension", "spinal"],
    "fatigue": ["als", "micro-gesture", "dwell"],
    "tremor": ["dwell", "sensitivity", "als"],
    "battery": ["charging", "telemetry", "wheelchair", "pi"],
}


def _expand_query(query: str) -> list[str]:
    tokens = _tokenize(query)
    expanded = list(tokens)
    for t in tokens:
        if t in _SYNONYMS:
            expanded.extend(_SYNONYMS[t])
    return expanded


@dataclass(frozen=True, slots=True)
class RetrievalResult:
    document_id: str
    title: str
    category: str
    snippet: str
    score: float

    def to_citation(self) -> AshaCitation:
        return AshaCitation(title=self.title, source_id=self.document_id)


class EmbeddedRAGRetriever:
    """Fast, local hybrid semantic and vector retriever for assistive medical and AAC queries."""

    def __init__(self, documents: Sequence[KnowledgeDocument] = CLINICAL_KNOWLEDGE_DOCUMENTS) -> None:
        self._documents: list[KnowledgeDocument] = list(documents)
        self._doc_tokens: list[list[str]] = []
        self._doc_freqs: dict[str, int] = defaultdict(int)
        self._doc_vectors: list[dict[str, float]] = []
        self._doc_norms: list[float] = []
        self._build_index()

    def _build_index(self) -> None:
        self._doc_tokens.clear()
        self._doc_freqs.clear()
        self._doc_vectors.clear()
        self._doc_norms.clear()

        num_docs = len(self._documents)
        if num_docs == 0:
            return

        # 1. Tokenize document text + title + keywords
        for doc in self._documents:
            text_body = f"{doc.title} {' '.join(doc.keywords)} {doc.summary} {doc.content}"
            tokens = _tokenize(text_body)
            self._doc_tokens.append(tokens)
            unique_tokens = set(tokens)
            for token in unique_tokens:
                self._doc_freqs[token] += 1

        # 2. Build TF-IDF vectors
        for tokens in self._doc_tokens:
            counts = Counter(tokens)
            total_terms = max(len(tokens), 1)
            vector: dict[str, float] = {}
            norm_sq = 0.0
            for term, count in counts.items():
                tf = count / total_terms
                idf = math.log((num_docs + 1) / (self._doc_freqs[term] + 1)) + 1.0
                weight = tf * idf
                vector[term] = weight
                norm_sq += weight * weight
            self._doc_vectors.append(vector)
            self._doc_norms.append(math.sqrt(norm_sq) if norm_sq > 0 else 1.0)

    def retrieve(
        self,
        query: str,
        *,
        top_k: int = 3,
        min_score: float = 0.08,
        category: str | None = None,
    ) -> list[RetrievalResult]:
        query_tokens = _expand_query(query)
        if not query_tokens or not self._documents:
            return []

        num_docs = len(self._documents)
        query_counts = Counter(query_tokens)
        query_total = len(query_tokens)
        query_vector: dict[str, float] = {}
        query_norm_sq = 0.0

        for term, count in query_counts.items():
            tf = count / query_total
            idf = math.log((num_docs + 1) / (self._doc_freqs.get(term, 0) + 1)) + 1.0
            weight = tf * idf
            query_vector[term] = weight
            query_norm_sq += weight * weight

        query_norm = math.sqrt(query_norm_sq) if query_norm_sq > 0 else 1.0

        scored_results: list[RetrievalResult] = []
        for idx, doc in enumerate(self._documents):
            if category is not None and doc.category != category:
                continue

            doc_vec = self._doc_vectors[idx]
            doc_norm = self._doc_norms[idx]

            # Vector cosine similarity
            dot_product = sum(
                weight * doc_vec.get(term, 0.0) for term, weight in query_vector.items()
            )
            cosine = dot_product / (query_norm * doc_norm) if (query_norm * doc_norm) > 0 else 0.0

            # Keyword direct match boost
            kw_match_count = sum(1 for kw in doc.keywords if kw in query.lower())
            title_match_count = sum(1 for tok in query_tokens if tok in doc.title.lower())
            boost = (kw_match_count * 0.15) + (title_match_count * 0.10)

            final_score = cosine + boost
            if final_score >= min_score:
                # Extract most relevant snippet
                snippet = self._extract_snippet(doc.content, query_tokens)
                scored_results.append(
                    RetrievalResult(
                        document_id=doc.id,
                        title=doc.title,
                        category=doc.category,
                        snippet=snippet,
                        score=round(final_score, 4),
                    )
                )

        scored_results.sort(key=lambda r: r.score, reverse=True)
        return scored_results[:top_k]

    def _extract_snippet(self, content: str, query_tokens: list[str]) -> str:
        sentences = re.split(r"(?<=[.!?\n])\s+", content)
        best_sentence = ""
        max_overlap = -1

        for sentence in sentences:
            sentence_clean = sentence.strip()
            if not sentence_clean:
                continue
            lower_s = sentence_clean.lower()
            overlap = sum(1 for t in query_tokens if t in lower_s)
            if overlap > max_overlap:
                max_overlap = overlap
                best_sentence = sentence_clean

        if best_sentence:
            return best_sentence[:350]
        return content[:350]

    async def plan(self, patient_context: AshaPatientContext | None) -> dict[str, object]:
        """Format the RAG retrieval tool definition for agentic LLM function calling."""
        del patient_context
        return {
            "type": "function",
            "function": {
                "name": "lookup_clinical_guidance",
                "description": (
                    "Search the verified assistive and clinical AAC knowledge base for ALS, "
                    "stroke recovery, seizure first aid, spinal cord injury, or wheelchair IoT operations."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {
                            "type": "string",
                            "description": "Medical or assistive care topic, e.g. 'seizure recovery position', 'ALS pacing', 'wheelchair battery'",
                        },
                        "category": {
                            "type": "string",
                            "enum": [
                                "als_mnd",
                                "stroke_aphasia",
                                "seizure_first_aid",
                                "spinal_cord_injury",
                                "device_operations",
                                "care_routine",
                                "bilingual_guidance",
                            ],
                            "description": "Optional category filter",
                        },
                    },
                    "required": ["query"],
                },
            },
        }
