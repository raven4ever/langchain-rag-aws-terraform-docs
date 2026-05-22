"""POST /ask — Phase 1: basic LCEL chain, no citations."""
from __future__ import annotations

import logging

from fastapi import APIRouter, HTTPException

from app.models import AskRequest, AskResponse
from app.rag.chain import build_chain

router = APIRouter(tags=["ask"])
logger = logging.getLogger(__name__)


@router.post("/ask", response_model=AskResponse)
async def ask(req: AskRequest) -> AskResponse:
    """Answer a question by invoking the RAG LCEL chain."""
    question = req.question.strip()
    if not question:
        raise HTTPException(status_code=422, detail="question must not be empty")

    chain = build_chain()
    try:
        answer = await chain.ainvoke(question)
    except Exception as exc:  # noqa: BLE001
        logger.exception("ask chain failed")
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    return AskResponse(answer=answer, sources=[])
