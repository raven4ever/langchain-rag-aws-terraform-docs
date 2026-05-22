"""Retriever wiring. Phase 2: EnsembleRetriever over Terraform + AWS subsets."""
from __future__ import annotations

from langchain.retrievers import EnsembleRetriever
from langchain_core.retrievers import BaseRetriever

from app.config import get_settings
from app.deps import get_vectorstore


def _subset_retriever(source: str, k: int) -> BaseRetriever:
    """Build a Chroma similarity retriever filtered to one corpus by metadata."""
    return get_vectorstore().as_retriever(
        search_kwargs={"k": k, "filter": {"source": source}},
    )


def build_retriever() -> BaseRetriever:
    """Build EnsembleRetriever combining terraform + aws subset retrievers."""
    s = get_settings()
    # Half the k per subset so the final ensemble lands near retrieval_k total.
    per_source_k = max(1, s.retrieval_k // 2)
    tf = _subset_retriever("terraform", per_source_k)
    aws = _subset_retriever("aws", per_source_k)
    return EnsembleRetriever(retrievers=[tf, aws], weights=[0.5, 0.5])
