"""LCEL chain assembly. Pipe-syntax only, no legacy chain classes."""
from __future__ import annotations

from functools import lru_cache

from langchain_core.documents import Document
from langchain_core.output_parsers import StrOutputParser
from langchain_core.runnables import Runnable, RunnableLambda, RunnablePassthrough

from app.deps import get_llm
from app.rag.prompts import ASK_PROMPT
from app.rag.retriever import build_retriever


def _format_context(docs: list[Document]) -> str:
    """Render retrieved chunks into prompt-ready text with doc_id headers."""
    if not docs:
        return "(no documents retrieved)"
    blocks = []
    for d in docs:
        doc_id = d.metadata.get("doc_id", "unknown")
        blocks.append(f"--- {doc_id} ---\n{d.page_content}")
    return "\n\n".join(blocks)


@lru_cache(maxsize=1)
def build_chain() -> Runnable:
    """Assemble cached LCEL /ask chain mapping question string to answer string."""
    retriever = build_retriever()
    llm = get_llm()
    format_ctx = RunnableLambda(_format_context)

    return (
        {
            "context": retriever | format_ctx,
            "question": RunnablePassthrough(),
        }
        | ASK_PROMPT
        | llm
        | StrOutputParser()
    )
