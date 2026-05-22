from typing import Literal

from pydantic import BaseModel, Field


SourceName = Literal["terraform", "aws"]
JobStatus = Literal["pending", "running", "complete", "failed"]


class IngestRequest(BaseModel):
    source: SourceName
    path: str = Field(..., description="Filesystem path inside the api container")
    service: str | None = None


class IngestResponse(BaseModel):
    job_id: str
    status: JobStatus


class IngestJob(BaseModel):
    job_id: str
    status: JobStatus
    source: SourceName
    path: str
    service: str | None = None
    chunks_ingested: int = 0
    error: str | None = None


class AskRequest(BaseModel):
    question: str
    conversation_id: str | None = None


class Source(BaseModel):
    id: int                   # the 1-indexed [N] citation marker from the answer
    source: SourceName        # "terraform" or "aws"
    doc_id: str
    page: int | None = None
    snippet: str


class AskResponse(BaseModel):
    answer: str
    sources: list[Source] = Field(default_factory=list)


class HealthResponse(BaseModel):
    status: Literal["ok", "degraded"]
    ollama: bool
    chroma: bool
    collection: str
    chunks: int | None = None
