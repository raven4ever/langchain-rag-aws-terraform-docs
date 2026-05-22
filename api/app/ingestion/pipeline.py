"""Ingestion orchestration. Phase 1 wires only the Terraform corpus."""
from __future__ import annotations

import logging
import threading
import time
import uuid
from typing import Callable

from langchain_core.documents import Document

from app.deps import get_vectorstore
from app.ingestion.loaders import load_aws, load_terraform
from app.ingestion.splitter import split_documents
from app.models import IngestJob, SourceName

logger = logging.getLogger(__name__)

# In-memory job registry. Process-local — fine for Phase 1.
_jobs: dict[str, IngestJob] = {}
_jobs_lock = threading.Lock()


_LOADERS: dict[SourceName, Callable[[str], list[Document]]] = {
    "terraform": load_terraform,
    "aws": load_aws,
}


def create_job(source: SourceName, path: str) -> IngestJob:
    """Create a pending ingest job and register it in the in-memory store."""
    job = IngestJob(
        job_id=str(uuid.uuid4()),
        status="pending",
        source=source,
        path=path,
    )
    with _jobs_lock:
        _jobs[job.job_id] = job
    return job


def get_job(job_id: str) -> IngestJob | None:
    """Return the job for the given id, or None if not found."""
    with _jobs_lock:
        return _jobs.get(job_id)


def _update(job_id: str, **fields) -> None:
    """Atomically update fields on the job with the given id."""
    with _jobs_lock:
        job = _jobs.get(job_id)
        if job is None:
            return
        _jobs[job_id] = job.model_copy(update=fields)


def run_ingest(job_id: str) -> None:
    """Execute load, split, and upsert for a job, updating its status throughout."""
    job = get_job(job_id)
    if job is None:
        logger.error("ingest job %s vanished before start", job_id)
        return

    start_ts = time.monotonic()
    logger.info(
        "ingest job %s STARTED (source=%s path=%s)", job_id, job.source, job.path
    )
    _update(job_id, status="running")
    try:
        loader = _LOADERS.get(job.source)
        if loader is None:
            raise ValueError(f"unsupported source: {job.source}")

        logger.info("loading %s docs from %s", job.source, job.path)
        raw_docs = loader(job.path)
        if not raw_docs:
            raise ValueError(f"no documents loaded from {job.path}")

        chunks = split_documents(raw_docs)
        logger.info("split %d docs into %d chunks", len(raw_docs), len(chunks))

        vs = get_vectorstore()
        # Stable IDs allow safe re-ingest (upsert on same chunk).
        ids = [
            f"{c.metadata.get('source')}::{c.metadata.get('doc_id')}::{i}"
            for i, c in enumerate(chunks)
        ]
        vs.add_documents(chunks, ids=ids)

        _update(job_id, status="complete", chunks_ingested=len(chunks))
        elapsed = time.monotonic() - start_ts
        logger.info(
            "ingest job %s FINISHED (chunks=%d elapsed=%.2fs)",
            job_id,
            len(chunks),
            elapsed,
        )
    except Exception as exc:  # noqa: BLE001
        elapsed = time.monotonic() - start_ts
        logger.exception(
            "ingest job %s FAILED after %.2fs", job_id, elapsed
        )
        _update(job_id, status="failed", error=str(exc))
