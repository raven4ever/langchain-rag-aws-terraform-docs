"""Prompt templates. Phase 1 has no citations — Phase 2 will add [N] markers."""
from langchain_core.prompts import ChatPromptTemplate


SYSTEM_PROMPT = """You are a helpful assistant answering questions about \
Terraform's AWS provider for IAM resources. Use ONLY the context below to \
answer. If the context does not contain the answer, say so plainly — do not \
guess and do not invent argument names. Prefer concrete Terraform HCL \
examples when helpful.

Context:
{context}
"""


ASK_PROMPT = ChatPromptTemplate.from_messages(
    [
        ("system", SYSTEM_PROMPT),
        ("human", "{question}"),
    ]
)
