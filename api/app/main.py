from fastapi import FastAPI

from app.api import ask, health, ingest

app = FastAPI(title="Terraform/AWS IAM RAG", version="0.1.0")

app.include_router(health.router)
app.include_router(ingest.router)
app.include_router(ask.router)
