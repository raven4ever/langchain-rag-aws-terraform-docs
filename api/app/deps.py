from functools import lru_cache

import chromadb
from langchain_chroma import Chroma
from langchain_ollama import ChatOllama, OllamaEmbeddings

from app.config import Settings, get_settings


@lru_cache(maxsize=1)
def get_chroma_client() -> chromadb.HttpClient:
    """Return cached Chroma HTTP client built from settings."""
    s = get_settings()
    return chromadb.HttpClient(host=s.chroma_host, port=s.chroma_port)


@lru_cache(maxsize=1)
def get_embeddings() -> OllamaEmbeddings:
    """Return cached Ollama embeddings client for the configured embed model."""
    s = get_settings()
    return OllamaEmbeddings(model=s.embed_model, base_url=s.ollama_base_url)


@lru_cache(maxsize=1)
def get_vectorstore() -> Chroma:
    """Return cached Chroma vectorstore wired to the shared client and embeddings."""
    s = get_settings()
    return Chroma(
        client=get_chroma_client(),
        collection_name=s.chroma_collection,
        embedding_function=get_embeddings(),
    )


@lru_cache(maxsize=1)
def get_llm() -> ChatOllama:
    """Return cached ChatOllama LLM configured with low temperature."""
    s = get_settings()
    return ChatOllama(model=s.llm_model, base_url=s.ollama_base_url, temperature=0.1)


def settings() -> Settings:
    """Return the cached Settings instance (thin alias for `get_settings`)."""
    return get_settings()
