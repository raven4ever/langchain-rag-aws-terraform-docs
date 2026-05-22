# TerraSage

A local-first retrieval-augmented Q&A API over the Terraform AWS provider documentation. Built as a learning project for LangChain RAG patterns. The first corpus covers AWS IAM; the design is service-agnostic so future corpora can be added without changing the stack.

## Purpose

TerraSage is a small RAG application that answers natural-language questions about configuring AWS through the Terraform AWS provider. It exists primarily to exercise LangChain's core RAG primitives (loaders, splitters, embeddings, vector stores, retrievers, LCEL chains) end-to-end against real documentation corpora.

Everything runs locally. No cloud APIs, no per-token costs. The api process runs natively on the host inside a Python venv; only Chroma runs in Docker; Ollama runs on the host. FastAPI (Python 3.14) serves the API, LangChain (LCEL) handles orchestration, Chroma stores vectors, and Ollama provides both the LLM and the embedding model.

## Requirements

- Docker and Docker Compose (only used to run Chroma)
- [Ollama](https://ollama.com) installed on the **host machine**
- Python **3.14** + `pip` (or `uv`) on the host — the api runs in a host venv
- ~5 GB free disk for the `llama3.1:8b` and `nomic-embed-text` model weights
- `jq` — used by `scripts/fetch_docs.sh` to filter the CloudFormation IAM spec
- `git`, used by `scripts/fetch_docs.sh` to sparse-checkout the Terraform provider repo

## Architecture

One container managed by `docker-compose.yml`, plus Ollama and the api process on the host:

| Service  | Image / Source        | Host port              | Purpose                                               |
| -------- | --------------------- | ---------------------- | ----------------------------------------------------- |
| `chroma` | `chromadb/chroma`     | 8001 (→ 8000 internal) | Persistent vector store                               |
| Ollama   | installed on the host | 11434                  | LLM (`llama3.1:8b`) + embeddings (`nomic-embed-text`) |

The api process runs directly on the host inside a Python venv and reaches both dependencies over `localhost` (Chroma on `localhost:8001`, Ollama on `localhost:11434`). Ollama deliberately lives outside the compose stack: model pulls don't get repeated on every restart, GPU access on the host is uncomplicated, and `ollama` commands can be run from a normal terminal.

## Startup flow

The commands below assume a fresh clone and that you have not yet installed Ollama.

### 1. Install Ollama on the host

Follow the instructions at https://ollama.com.

### 2. Pull the models

```bash
./scripts/bootstrap_ollama.sh
```

This calls `ollama pull llama3.1:8b` and `ollama pull nomic-embed-text` on the host. Allow several minutes for the first run.

### 3. Fetch source documents

```bash
./scripts/fetch_docs.sh
```

This sparse-checks-out `hashicorp/terraform-provider-aws` and populates `./data/<svc>/{terraform,aws}/` for each service in `SERVICES_LIST` (IAM by default).

By default the script fetches docs for the top 10 AWS services: `iam s3 ec2
vpc lambda rds cloudwatch cloudformation route53 dynamodb`. Override the set
with the `SERVICES` env var:

```bash
SERVICES="iam s3" ./scripts/fetch_docs.sh
```

For each service the script pulls (a) Terraform provider docs filtered by the
`<svc>_*.html.markdown` filename prefix, (b) the AWS User Guide and API
Reference PDFs, and (c) a CloudFormation resource spec filtered to
`AWS::<Service>::*`. `jq` is a soft dep — if missing, the full unfiltered CFN
spec is copied into every service dir instead. Adding a new service means
adding a case arm to `aws_urls()` inside the script.

### 4. Bring up Chroma

```bash
docker compose up -d
```

Only Chroma runs in Docker.

### 5. Set up the api venv and run it

```bash
cd api
python3.14 -m venv .venv
source .venv/bin/activate
pip install .
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

### 6. Verify health

```bash
curl -s http://localhost:8000/health | python3 -m json.tool
```

Expected response:

```json
{
  "status": "ok",
  "ollama": true,
  "chroma": true
}
```

### 7. (Optional) Run the smoke test

```bash
./scripts/smoke_test.sh
```

Calls `/ingest` for every service in `SERVICES_LIST` and asks the 5-question battery against the running stack.

## Data folder layout

`./scripts/fetch_docs.sh` populates one subdirectory per service under `data/`, with separate `terraform/` and `aws/` subfolders so each corpus stays isolated.

The `/ingest` endpoint expects `path` pointing at one of these leaf corpora — e.g. `./data/iam/terraform` or `./data/s3/aws` — plus a `service` field so the job log lines name the service. The smoke test loops over every service in `SERVICES_LIST` and runs one ingest per (service, source) pair.

## Ingesting and asking

Ingest the Terraform corpus for IAM:

```bash
curl -X POST http://localhost:8000/ingest \
  -H 'Content-Type: application/json' \
  -d '{"source": "terraform", "path": "./data/iam/terraform", "service": "iam"}'
```

Response includes a `job_id`. Poll for completion:

```bash
curl -s http://localhost:8000/ingest/<job_id> | python3 -m json.tool
```

Wait for `"status": "complete"`. Then ingest the AWS corpus:

```bash
curl -X POST http://localhost:8000/ingest \
  -H 'Content-Type: application/json' \
  -d '{"source": "aws", "path": "./data/iam/aws", "service": "iam"}'
```

Ask a question:

```bash
curl -X POST http://localhost:8000/ask \
  -H 'Content-Type: application/json' \
  -d '{"question": "How do I create an IAM role with a custom trust policy in Terraform?"}'
```

## Interactive API docs

FastAPI auto-generates an OpenAPI schema and serves two browser UIs:

- **Swagger UI** — http://localhost:8000/docs (try-it-out form for every endpoint)
- **ReDoc** — http://localhost:8000/redoc (read-only reference)
- Raw schema — http://localhost:8000/openapi.json (importable into Postman/Insomnia if needed)

## Smoke test

Make sure the api is already running (step 5).

```bash
./scripts/smoke_test.sh
```

Runs the full happy path against the running stack using a small fixture corpus and asserts that the resulting answer contains `assume_role_policy`. Set the `TIMEOUT_S` environment variable if the LLM takes longer than the default (e.g. on CPU-only hardware):

```bash
TIMEOUT_S=180 ./scripts/smoke_test.sh
```
