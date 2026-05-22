import logging

from fastapi import FastAPI

from app.api import ask, health, ingest

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)

app = FastAPI(title="TerraSage", version="0.1.0")

app.include_router(health.router)
app.include_router(ingest.router)
app.include_router(ask.router)
