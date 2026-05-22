"""GET /health — does the API + its dependencies look alive."""
from __future__ import annotations

import logging

import httpx
from fastapi import APIRouter

from app.config import get_settings
from app.deps import get_chroma_client
from app.models import HealthResponse

router = APIRouter(tags=["health"])
logger = logging.getLogger(__name__)


def _ollama_ok(base_url: str) -> bool:
    """Probe Ollama /api/tags and return True on HTTP 200."""
    try:
        r = httpx.get(f"{base_url}/api/tags", timeout=2.0)
        return r.status_code == 200
    except Exception as exc:  # noqa: BLE001
        logger.warning("ollama healthcheck failed: %s", exc)
        return False


def _chroma_stats() -> tuple[bool, int | None]:
    """Return Chroma reachability and collection chunk count when available."""
    s = get_settings()
    try:
        client = get_chroma_client()
        client.heartbeat()
        try:
            col = client.get_or_create_collection(s.chroma_collection)
            return True, col.count()
        except Exception:  # noqa: BLE001
            return True, None
    except Exception as exc:  # noqa: BLE001
        logger.warning("chroma healthcheck failed: %s", exc)
        return False, None


@router.get("/health", response_model=HealthResponse)
def health() -> HealthResponse:
    """Report API plus Ollama and Chroma dependency status."""
    s = get_settings()
    ollama = _ollama_ok(s.ollama_base_url)
    chroma_ok, chunks = _chroma_stats()
    status = "ok" if (ollama and chroma_ok) else "degraded"
    return HealthResponse(
        status=status,
        ollama=ollama,
        chroma=chroma_ok,
        collection=s.chroma_collection,
        chunks=chunks,
    )
