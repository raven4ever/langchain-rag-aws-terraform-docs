"""Retriever wiring. Phase 1: single Chroma similarity retriever.

Phase 2 will swap this for an EnsembleRetriever combining [TF] and [AWS]
collections (or metadata-filtered views of one collection).
"""
from __future__ import annotations

from langchain_core.retrievers import BaseRetriever

from app.config import get_settings
from app.deps import get_vectorstore


def build_retriever() -> BaseRetriever:
    """Build Chroma similarity retriever using configured top-k."""
    s = get_settings()
    return get_vectorstore().as_retriever(search_kwargs={"k": s.retrieval_k})
