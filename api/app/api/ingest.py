"""POST /ingest, GET /ingest/{job_id}."""
from __future__ import annotations

from fastapi import APIRouter, BackgroundTasks, HTTPException

from app.ingestion.pipeline import create_job, get_job, run_ingest
from app.models import IngestJob, IngestRequest, IngestResponse

router = APIRouter(tags=["ingest"])


@router.post("/ingest", response_model=IngestResponse, status_code=202)
def start_ingest(req: IngestRequest, background: BackgroundTasks) -> IngestResponse:
    """Create ingest job and schedule background run."""
    job = create_job(req.source, req.path)
    background.add_task(run_ingest, job.job_id)
    return IngestResponse(job_id=job.job_id, status=job.status)


@router.get("/ingest/{job_id}", response_model=IngestJob)
def ingest_status(job_id: str) -> IngestJob:
    """Return job state by id or 404 if unknown."""
    job = get_job(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="unknown job_id")
    return job
