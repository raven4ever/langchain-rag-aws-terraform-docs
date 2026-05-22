"""LCEL chain assembly. Phase 2: returns answer + retrieved docs (for citations)."""
from __future__ import annotations

from functools import lru_cache

from langchain_core.documents import Document
from langchain_core.output_parsers import StrOutputParser
from langchain_core.runnables import Runnable, RunnableLambda, RunnablePassthrough

from app.deps import get_llm
from app.rag.prompts import ASK_PROMPT
from app.rag.retriever import build_retriever


def _source_tag(doc: Document) -> str:
    """Return a `[TF: doc_id]` or `[AWS: doc_id]` tag for a retrieved chunk."""
    src = doc.metadata.get("source", "unknown")
    doc_id = doc.metadata.get("doc_id", "unknown")
    page = doc.metadata.get("page")
    prefix = "TF" if src == "terraform" else ("AWS" if src == "aws" else src.upper())
    if page is not None:
        return f"[{prefix}: {doc_id} p.{page}]"
    return f"[{prefix}: {doc_id}]"


def _format_context(docs: list[Document]) -> str:
    """Render retrieved chunks with 1-indexed [N] markers and [TF]/[AWS] tags."""
    if not docs:
        return "(no documents retrieved)"
    blocks = []
    for i, d in enumerate(docs, start=1):
        blocks.append(f"[{i}] {_source_tag(d)}\n{d.page_content}")
    return "\n\n".join(blocks)


@lru_cache(maxsize=1)
def build_chain() -> Runnable:
    """Build LCEL chain returning {'answer': str, 'docs': list[Document]} given a question."""
    retriever = build_retriever()
    llm = get_llm()

    # Retrieve docs once, fan them into both the prompt context and the output.
    retrieve = RunnableLambda(lambda q: retriever.invoke(q))
    format_ctx = RunnableLambda(_format_context)

    answer_chain = (
        {
            "context": (lambda x: x["docs"]) | format_ctx,
            "question": lambda x: x["question"],
        }
        | ASK_PROMPT
        | llm
        | StrOutputParser()
    )

    # Input: a question string. Stage 1 attaches docs; stage 2 produces the answer
    # while keeping docs around for the response builder.
    return (
        {"question": RunnablePassthrough(), "docs": retrieve}
        | RunnablePassthrough.assign(answer=answer_chain)
        | (lambda x: {"answer": x["answer"], "docs": x["docs"]})
    )
