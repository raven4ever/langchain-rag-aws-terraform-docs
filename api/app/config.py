from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    ollama_base_url: str = "http://ollama:11434"
    chroma_host: str = "chroma"
    chroma_port: int = 8000
    llm_model: str = "llama3.1:8b"
    embed_model: str = "nomic-embed-text"
    chroma_collection: str = "iam_docs"
    data_dir: str = "/data"

    retrieval_k: int = 4
    chunk_size: int = 1000
    chunk_overlap: int = 150


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Return cached Settings loaded from environment and `.env`."""
    return Settings()
