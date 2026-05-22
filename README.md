# TerraSage

A local-first retrieval-augmented Q&A API over the Terraform AWS provider documentation. Built as a learning project for LangChain RAG patterns. The first corpus covers AWS IAM; the design is service-agnostic so future corpora can be added without changing the stack.

## Purpose

TerraSage is a small RAG application that answers natural-language questions about configuring AWS through the Terraform AWS provider. It exists primarily to exercise LangChain's core RAG primitives (loaders, splitters, embeddings, vector stores, retrievers, LCEL chains) end-to-end against real documentation corpora.

Everything runs locally. No cloud APIs, no per-token costs. The stack is Docker Compose plus a host-side Ollama: FastAPI (Python 3.14) for the API, LangChain (LCEL) for orchestration, Chroma for vector storage, and Ollama for both the LLM and the embedding model.

## Requirements

- Docker and Docker Compose (Docker Engine >= 20.10 — required for the `host-gateway` magic value in `extra_hosts`)
- [Ollama](https://ollama.com) installed on the **host machine** (not in a container)
- ~5 GB free disk for the `llama3.1:8b` and `nomic-embed-text` model weights
- Python is **not** required on the host — the api runs inside its container
- `git`, used by `scripts/fetch_docs.sh` to sparse-checkout the Terraform provider repo

## Architecture

Two containers managed by `docker-compose.yml`, plus Ollama on the host:

| Service  | Image / Source              | Host port              | Purpose                                               |
| -------- | --------------------------- | ---------------------- | ----------------------------------------------------- |
| `api`    | built from `api/Dockerfile` | 8000                   | FastAPI + LangChain LCEL chain                        |
| `chroma` | `chromadb/chroma`           | 8001 (→ 8000 internal) | Persistent vector store                               |
| Ollama   | installed on the host       | 11434                  | LLM (`llama3.1:8b`) + embeddings (`nomic-embed-text`) |

Containers reach Ollama via `host.docker.internal:11434`. Ollama deliberately lives outside the compose stack: model pulls don't get repeated on every container rebuild, GPU access on the host is uncomplicated, and `ollama` commands can be run from a normal terminal.

Persistence: the `chroma` service writes to a named Docker volume; source documents live on disk under `./data/` and are mounted read-only into the api container.

## Startup flow

The commands below assume a fresh clone and that you have not yet installed Ollama.

### 1. Install Ollama on the host

Follow the instructions at https://ollama.com.

### 2. Make Ollama listen on all interfaces

Out of the box Ollama binds to `127.0.0.1:11434`, which the Docker bridge cannot reach. Bind it to `0.0.0.0` instead.

**macOS:**

```bash
launchctl setenv OLLAMA_HOST "0.0.0.0:11434"
```

Then **fully quit the Ollama menu-bar app and relaunch it**. `launchctl setenv` only affects processes started after the call.

**Linux (systemd):**

```bash
sudo systemctl edit ollama.service
```

Add the following under `[Service]`:

```
Environment="OLLAMA_HOST=0.0.0.0:11434"
```

Then:

```bash
sudo systemctl restart ollama
```

**Verify (both platforms):**

```bash
curl http://localhost:11434/api/tags
```

Should return JSON (an empty `models` list is fine; an empty body or connection-refused is not).

### 3. Pull the models

```bash
./scripts/bootstrap_ollama.sh
```

This calls `ollama pull llama3.1:8b` and `ollama pull nomic-embed-text` on the host. Allow several minutes for the first run.

### 4. Fetch source documents

```bash
./scripts/fetch_docs.sh
```

This sparse-checks-out `hashicorp/terraform-provider-aws` and copies the IAM resource/data-source markdown into `./data/terraform/`.

### 5. Bring up the stack

```bash
docker compose up -d
```

Starts `chroma` and `api`. Ollama is already running on the host.

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

### 7. Ingest the corpus

```bash
curl -X POST http://localhost:8000/ingest \
  -H 'Content-Type: application/json' \
  -d '{"source": "terraform", "path": "/data/terraform"}'
```

Response includes a `job_id`. Poll for completion:

```bash
curl -s http://localhost:8000/ingest/<job_id> | python3 -m json.tool
```

Wait for `"status": "complete"`.

### 8. Ask a question

```bash
curl -X POST http://localhost:8000/ask \
  -H 'Content-Type: application/json' \
  -d '{"question": "How do I create an IAM role with a custom trust policy in Terraform?"}'
```

## Running the API outside Docker

For local Python development (without rebuilding the container on each change), the api can be run directly. This is the only case where `.env` matters — `pydantic-settings` loads it at startup. The compose stack passes all settings via the `environment:` block instead, so `.env` is ignored when running in the container.

```bash
cd api
cp ../.env.example ../.env   # then edit values for your host (e.g. CHROMA_HOST=localhost, CHROMA_PORT=8001)
pip install -e .
uvicorn app.main:app --reload --port 8000
```

## Smoke test

```bash
./scripts/smoke_test.sh
```

Runs the full happy path against the running stack using a small fixture corpus and asserts that the resulting answer contains `assume_role_policy`. Set the `TIMEOUT_S` environment variable if the LLM takes longer than the default (e.g. on CPU-only hardware):

```bash
TIMEOUT_S=180 ./scripts/smoke_test.sh
```

## Common issues

### 1. `/health` returns `ollama: false`, or `Connection refused` on port 11434

**Cause**: Ollama is still bound to `127.0.0.1:11434`. The Docker bridge cannot reach host loopback addresses.

**Diagnosis**:

```bash
lsof -iTCP:11434 -sTCP:LISTEN
# Want: *:11434
# Not:  127.0.0.1:11434

launchctl getenv OLLAMA_HOST   # macOS — should print 0.0.0.0:11434
```

**Fix**: set `OLLAMA_HOST=0.0.0.0:11434` per Startup flow step 2. On macOS the menu-bar app must be **fully quit and relaunched** — `launchctl setenv` only takes effect for newly-spawned processes.

### 2. `fetch_docs.sh` fails with `Permission denied` writing to `./data/`

**Cause**: a previous container run created files in `./data/` as root, locking out your host user.

**Fix**:

```bash
sudo rm -rf data/.tf_checkout data/terraform data/aws
mkdir -p data
```

The api container currently runs as root, so any files it writes into the bind-mounted `./data/` end up root-owned. If this becomes recurring, add a `user: "${HOST_UID}:${HOST_GID}"` directive to the `api` service in `docker-compose.yml` and supply `HOST_UID`/`HOST_GID` in `.env`.

### 3. Linux: `host.docker.internal` does not resolve from inside the api container

**Cause**: Docker on Linux does not automatically create the `host.docker.internal` hostname (it is a macOS/Windows Docker Desktop convenience).

**Fix**: `docker-compose.yml` declares this for the `api` service:

```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

The `host-gateway` magic value requires Docker Engine >= 20.10. If you are still stuck, check that `ufw`/`iptables` is not blocking the Docker bridge from reaching host port 11434.

### 4. The `chroma` container has no healthcheck

**Cause**: the `chromadb/chroma` image ships without `python`, `curl`, or a healthcheck CLI subcommand, so there is no good in-container probe.

**Fix**: there is intentionally no healthcheck defined on `chroma`. The `api` service uses `depends_on: { chroma: { condition: service_started } }` instead of `service_healthy`. Overall readiness is exposed by the api's `/health` endpoint, which performs a live round-trip to Chroma.

### 5. Re-running `/ingest` produces duplicate chunks

This was a real problem early on and is now resolved: each chunk is keyed by a stable ID of the form `source::doc_id::chunk_idx`, so re-ingestion upserts rather than appends. You can re-ingest as often as you want without inflating the collection.
