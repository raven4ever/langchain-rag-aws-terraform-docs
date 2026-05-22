from typing import Literal

from pydantic import BaseModel, Field


SourceName = Literal["terraform", "aws"]
JobStatus = Literal["pending", "running", "complete", "failed"]


class IngestRequest(BaseModel):
    source: SourceName
    path: str = Field(..., description="Filesystem path inside the api container")


class IngestResponse(BaseModel):
    job_id: str
    status: JobStatus


class IngestJob(BaseModel):
    job_id: str
    status: JobStatus
    source: SourceName
    path: str
    chunks_ingested: int = 0
    error: str | None = None


class AskRequest(BaseModel):
    question: str
    conversation_id: str | None = None


class AskResponse(BaseModel):
    answer: str
    # Phase 1: empty list. Phase 2 fills with citations.
    sources: list[dict] = Field(default_factory=list)


class HealthResponse(BaseModel):
    status: Literal["ok", "degraded"]
    ollama: bool
    chroma: bool
    collection: str
    chunks: int | None = None
