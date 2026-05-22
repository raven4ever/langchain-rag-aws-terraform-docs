from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    ollama_base_url: str = "http://localhost:11434"
    chroma_host: str = "localhost"
    chroma_port: int = 8001
    llm_model: str = "llama3.1:8b"
    embed_model: str = "nomic-embed-text:latest"
    chroma_collection: str = "iam_docs"
    data_dir: str = "./data"

    retrieval_k: int = 4
    chunk_size: int = 1000
    chunk_overlap: int = 150

    # Ingest batching — used to keep upserts under Chroma's HTTP payload cap.
    embed_dim: int = 768                       # nomic-embed-text=768, mxbai-large=1024, bge-m3=1024
    chroma_http_max_bytes: int = 4 * 1024 * 1024  # conservative; many proxies cap at 4MB


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Return cached Settings loaded from environment and `.env`."""
    return Settings()
