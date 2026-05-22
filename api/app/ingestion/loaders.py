"""Per-source loaders. Phase 1: Terraform markdown only."""
from __future__ import annotations

import re
from pathlib import Path

from langchain_community.document_loaders import PyPDFLoader, TextLoader
from langchain_core.documents import Document


RESOURCE_RE = re.compile(r"^(aws_[a-z0-9_]+)\.html\.markdown$")


def _resource_type(filename: str) -> str | None:
    """Extract aws_* resource type from Terraform doc filename."""
    m = RESOURCE_RE.match(filename)
    return m.group(1) if m else None


def load_terraform(path: str) -> list[Document]:
    """Load Terraform AWS provider markdown docs from directory with metadata."""
    root = Path(path)
    if not root.exists():
        raise FileNotFoundError(f"path not found: {path}")

    files: list[Path] = []
    for pattern in ("**/*.markdown", "**/*.md"):
        files.extend(root.glob(pattern))

    docs: list[Document] = []
    for f in sorted(set(files)):
        loader = TextLoader(str(f), encoding="utf-8")
        for doc in loader.load():
            doc.metadata.update(
                {
                    "source": "terraform",
                    "service": "iam",
                    "doc_id": f.name,
                    "path": str(f.relative_to(root)),
                }
            )
            rt = _resource_type(f.name)
            if rt:
                doc.metadata["resource_type"] = rt
            docs.append(doc)
    return docs


def load_aws(path: str) -> list[Document]:
    """Load AWS IAM docs (PDF, Markdown, JSON) from directory with metadata."""
    root = Path(path)
    if not root.exists():
        raise FileNotFoundError(f"path not found: {path}")

    files: list[Path] = []
    for pattern in ("**/*.pdf", "**/*.md", "**/*.json"):
        files.extend(root.glob(pattern))

    docs: list[Document] = []
    for f in sorted(set(files)):
        suffix = f.suffix.lower()
        if suffix == ".pdf":
            loaded = PyPDFLoader(str(f)).load()
        else:
            loaded = TextLoader(str(f), encoding="utf-8").load()

        for doc in loaded:
            meta = {
                "source": "aws",
                "service": "iam",
                "doc_id": f.name,
                "path": str(f.relative_to(root)),
            }
            if suffix == ".pdf":
                page = doc.metadata.get("page")
                if page is not None:
                    meta["page"] = int(page)
            doc.metadata.update(meta)
            docs.append(doc)
    return docs
