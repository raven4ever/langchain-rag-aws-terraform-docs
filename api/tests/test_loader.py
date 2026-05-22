"""Offline tests for ingestion primitives (no Ollama/Chroma required)."""
from pathlib import Path

from app.ingestion.loaders import load_terraform
from app.ingestion.splitter import split_documents


FIXTURE_DIR = Path(__file__).parent / "fixtures" / "terraform"


def test_load_terraform_tags_metadata():
    """Verify Terraform loader tags each document with required metadata fields."""
    docs = load_terraform(str(FIXTURE_DIR))
    assert docs, "expected at least one doc loaded"
    d = docs[0]
    assert d.metadata["source"] == "terraform"
    assert d.metadata["service"] == "iam"
    assert d.metadata["doc_id"] == "iam_role_smoke.html.markdown"
    assert "assume_role_policy" in d.page_content


def test_split_documents_produces_chunks():
    """Assert splitter emits non-empty chunks that retain source metadata."""
    docs = load_terraform(str(FIXTURE_DIR))
    chunks = split_documents(docs)
    assert chunks, "splitter returned no chunks"
    # Metadata must survive the split.
    assert all(c.metadata.get("source") == "terraform" for c in chunks)
