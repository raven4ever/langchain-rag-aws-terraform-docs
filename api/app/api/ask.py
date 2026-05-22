"""POST /ask — Phase 2: dual-source RAG with inline [N] citations."""
from __future__ import annotations

import logging
import re

from fastapi import APIRouter, HTTPException
from langchain_core.documents import Document

from app.models import AskRequest, AskResponse, Source, SourceName
from app.rag.chain import build_chain

router = APIRouter(tags=["ask"])
logger = logging.getLogger(__name__)

_CITE_RE = re.compile(r"\[(\d+)\]")
_SNIPPET_LEN = 240


def _build_sources(answer: str, docs: list[Document]) -> list[Source]:
    """Pair each [N] marker in the answer with metadata of docs[N-1]."""
    seen: set[int] = set()
    out: list[Source] = []
    for match in _CITE_RE.finditer(answer):
        n = int(match.group(1))
        if n in seen or n < 1 or n > len(docs):
            continue
        seen.add(n)
        d = docs[n - 1]
        meta = d.metadata or {}
        src_value: SourceName = meta.get("source", "terraform")  # type: ignore[assignment]
        snippet = d.page_content[:_SNIPPET_LEN].strip()
        out.append(
            Source(
                id=n,
                source=src_value,
                doc_id=meta.get("doc_id", "unknown"),
                page=meta.get("page"),
                snippet=snippet,
            )
        )
    return out


@router.post("/ask", response_model=AskResponse)
async def ask(req: AskRequest) -> AskResponse:
    """Answer a question via the RAG chain and attach inline-cited sources."""
    question = req.question.strip()
    if not question:
        raise HTTPException(status_code=422, detail="question must not be empty")

    chain = build_chain()
    try:
        result = await chain.ainvoke(question)
    except Exception as exc:  # noqa: BLE001
        logger.exception("ask chain failed")
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    answer = result["answer"]
    docs = result["docs"]
    sources = _build_sources(answer, docs)
    return AskResponse(answer=answer, sources=sources)
