# CLAUDE.md

Project context for Claude Code. This file captures the decisions and design for a local-first RAG application built to learn LangChain.

---

## Project Overview

A retrieval-augmented Q&A API that answers questions about **Terraform AWS provider configuration**, cross-referencing the official **AWS service documentation** (scoped to IAM). Built primarily as a learning exercise for LangChain RAG patterns, runs entirely locally via Docker Compose, no cloud API keys required.

## Goals & Non-Goals

**Goals**

- Learn LangChain's core RAG primitives end-to-end: loaders, splitters, embeddings, vector stores, retrievers, prompt templates, LCEL chains, output parsers.
- Build something genuinely useful: a Q&A tool over Terraform + AWS docs.
- Keep the entire stack local — no OpenAI/Bedrock/Anthropic API calls, no per-token costs while iterating.
- Multi-corpus retrieval with source-attributed citations.

**Non-Goals**

- Production deployment, auth, or multi-tenancy.
- High throughput or low latency tuning — slow is fine.
- Frontend UI — API only, curl/Postman is the client.
- Unit Tests.

## Tech Stack

- **API framework**: FastAPI (Python 3.11+)
- **Orchestration**: LangChain (use LCEL / `|` pipe syntax, not legacy `LLMChain`)
- **LLM + Embeddings**: Ollama
  - LLM: `llama3.1:8b` (start with `llama3.2:3b` if hardware is constrained)
  - Embeddings: `nomic-embed-text`
- **Vector store**: Chroma (server mode, separate container)
- **Containerization**: Docker Compose
- **Observability** (optional): LangSmith for tracing

## Architecture

Three services in `docker-compose.yml`:

| Service  | Image / Build             | Port                           | Purpose                 |
| -------- | ------------------------- | ------------------------------ | ----------------------- |
| `api`    | local Dockerfile (Python) | 8000                           | FastAPI + LangChain     |
| `ollama` | `ollama/ollama`           | 11434                          | LLM and embedding model |
| `chroma` | `chromadb/chroma`         | 8001 (host) → 8000 (container) | Persistent vector store |

Named volumes for persistence: `ollama_models`, `chroma_data`. Source docs mounted from `./data/` into the api container.

Communication: all internal traffic over the Docker Compose network. The api container reaches Ollama at `http://ollama:11434` and Chroma at `chroma:8000`.

## Knowledge Base

Two corpora, scoped to **AWS IAM** to keep ingestion manageable.

### Corpus 1: Terraform AWS provider docs (IAM resources only)

- **Source**: `hashicorp/terraform-provider-aws` GitHub repo
- **Path within repo**: `website/docs/r/iam_*.html.markdown` and `website/docs/d/iam_*.html.markdown`
- **Format**: Markdown (clean, structured)
- **Local location**: `./data/terraform/`

### Corpus 2: AWS IAM documentation

- **Source**: AWS IAM User Guide (PDF) + AWS IAM API Reference + CloudFormation IAM resource spec (JSON)
- **Why this combo**: avoids scraping `docs.aws.amazon.com` directly. PDF gives prose, API ref gives operations, CFN spec gives authoritative resource schemas.
- **Local location**: `./data/aws/`

### Metadata tagging

Every chunk in Chroma carries:

- `source`: `"terraform"` or `"aws"`
- `service`: `"iam"` (anticipating future expansion to other services)
- `doc_id`: filename or stable identifier
- `page` / `section`: for citations
- Optional: `resource_type` (e.g., `aws_iam_role`) for Terraform chunks

## API Surface

```
POST /ingest
  Body: { "source": "terraform" | "aws", "path": "./data/terraform/" }
  Behavior: kicks off background ingestion task, returns immediately with job id
  Response: { "job_id": "...", "status": "pending" }

GET /ingest/{job_id}
  Returns: { "status": "pending|running|complete|failed", "chunks_ingested": N }

POST /ask
  Body: {
    "question": "...",
    "conversation_id": "..." (optional, deferred for now)
  }
  Response: {
    "answer": "Use [TF] aws_iam_role with assume_role_policy [1]. Per [AWS] docs, the trust policy specifies which principals can assume the role [2].",
    "sources": [
      { "id": 1, "source": "terraform", "doc_id": "iam_role.html.markdown", "snippet": "..." },
      { "id": 2, "source": "aws", "doc_id": "iam-user-guide.pdf", "page": 42, "snippet": "..." }
    ]
  }

GET /health
  Returns service + dependency health
```

## RAG Pipeline

### Ingestion path (runs at /ingest, NOT at startup)

```
Documents on disk
  → DirectoryLoader / PyPDFLoader (per source type)
  → RecursiveCharacterTextSplitter (chunk_size=1000, overlap=150 as starting point)
  → OllamaEmbeddings (nomic-embed-text)
  → Chroma.add_documents() with metadata tagging
```

Run as a FastAPI `BackgroundTasks` job. Chroma persists to its named volume; original docs stay on disk for re-ingestion.

### Query path (runs at /ask)

```
Question
  → EnsembleRetriever (combines tf_retriever + aws_retriever, weights=[0.5, 0.5])
      ↳ each retriever embeds the question and does similarity_search on its Chroma collection (or on a metadata-filtered single collection)
  → Format retrieved chunks with source markers ([TF: <doc>] / [AWS: <doc>])
  → ChatPromptTemplate (system prompt + question + context)
  → ChatOllama (llama3.1:8b)
  → StrOutputParser
  → Response builder: pair the model's [1], [2] citations with the retrieved chunks' metadata
```

### Prompt design for dual-source RAG

Key prompt instructions to bake in:

- Distinguish [TF] (Terraform provider docs) from [AWS] (AWS service docs)
- Use [TF] for argument names, types, Terraform-specific syntax
- Use [AWS] for underlying service behavior, semantics, constraints
- If the two sources disagree, point it out explicitly
- Cite every factual claim with inline `[N]` markers

## Project Structure

```
.
├── CLAUDE.md                  # this file
├── docker-compose.yml
├── .env.example
├── data/                      # source docs (gitignored)
│   ├── terraform/
│   └── aws/
├── api/
│   ├── Dockerfile
│   ├── pyproject.toml
│   ├── app/
│   │   ├── __init__.py
│   │   ├── main.py            # FastAPI app, lifespan, routes
│   │   ├── config.py          # env vars (Ollama URL, Chroma host, model names)
│   │   ├── deps.py            # shared resources (vectorstore, llm, chain)
│   │   ├── ingestion/
│   │   │   ├── loaders.py     # per-source-type loaders
│   │   │   ├── splitter.py    # chunking config
│   │   │   └── pipeline.py    # ingestion orchestration
│   │   ├── rag/
│   │   │   ├── retriever.py   # EnsembleRetriever setup
│   │   │   ├── prompts.py     # ChatPromptTemplate definitions
│   │   │   └── chain.py       # LCEL chain assembly
│   │   ├── api/
│   │   │   ├── ask.py         # POST /ask
│   │   │   ├── ingest.py      # POST /ingest
│   │   │   └── health.py
│   │   └── models.py          # Pydantic request/response shapes
│   └── tests/
└── scripts/
    └── fetch_docs.sh          # downloads Terraform docs + AWS PDFs into ./data/
```

## Development Workflow

```bash
# First-time setup
docker compose up -d ollama chroma
docker compose exec ollama ollama pull llama3.1:8b
docker compose exec ollama ollama pull nomic-embed-text
./scripts/fetch_docs.sh           # populate ./data/

# Bring up the API
docker compose up -d api

# Ingest
curl -X POST http://localhost:8000/ingest \
  -H 'Content-Type: application/json' \
  -d '{"source": "terraform", "path": "./data/terraform/"}'

curl -X POST http://localhost:8000/ingest \
  -H 'Content-Type: application/json' \
  -d '{"source": "aws", "path": "./data/aws/"}'

# Ask
curl -X POST http://localhost:8000/ask \
  -H 'Content-Type: application/json' \
  -d '{"question": "How do I create an IAM role with a custom trust policy in Terraform?"}'
```

## Development Approach

Use one or many **caveman agents** for development, testing or documentation activities, optionally organized into teams with different specialties. There is no required structure — use whatever decomposition makes the work go faster — but the project decomposes naturally along these lines:

- **API / backend agent** — FastAPI app structure, endpoints, request/response models, background tasks, error handling.
- **LangChain / RAG agent** — ingestion pipeline, document loaders, splitters, retrievers, prompt design, LCEL chain assembly.
- **Infrastructure agent** — Dockerfile, docker-compose.yml, volumes, networking, Ollama model bootstrapping.
- **Testing agent** — runs tests for each phase's deliverable, validates acceptance criteria before a phase is declared complete.
- **Reviewer agent** — sanity-checks code against this CLAUDE.md before phase closure, flags drift from the documented design.

Caveman agents can be used singly or organized into a team of specialists, whichever fits the work. The constraints, regardless of structure, are:

1. **Every feature must be tested as well as implemented.** Implementation without verification does not count as done. Tests are part of the phase deliverable, not a follow-up.
2. **Agents must treat this CLAUDE.md as the spec.** If an agent needs to deviate from a documented decision, the deviation gets recorded back into CLAUDE.md _before_ the code change lands.
3. **Cross-agent handoffs go through CLAUDE.md or the codebase**, not through assumed shared context. Any agent picking up work should be able to orient from the file + the code alone.

## Development Phases

Development proceeds in phases. **Each phase must end with a stable, runnable application that delivers a clearly stated, demonstrable piece of functionality.** Do not start the next phase until the current phase's acceptance criteria are met and the app runs end-to-end without errors.

### Phase principles

- Each phase ends with a green build: `docker compose up` works, no startup errors, the documented endpoints respond.
- Each phase delivers a _complete_ feature, not a half-implemented one. A partially-working RAG that "almost works" is not an acceptable phase boundary.
- If a phase grows too large during execution, split it into sub-phases before starting — partial phases are not valid stopping points.
- Tests for the phase's functionality must pass before declaring the phase complete, even when overall test coverage is minimal.
- At every phase boundary, the app must be in a state where someone could stop work here, hand the repo to a stranger, and have them run it.

### Phase 1 — single corpus, end-to-end Q&A

Goal: prove the full RAG loop works against one source.

- [ ] docker-compose with all three services (api, ollama, chroma), healthchecks defined
- [ ] Ollama model pull documented (or scripted) for `llama3.1:8b` and `nomic-embed-text`
- [ ] `/health` endpoint returns dependency status
- [ ] `/ingest` endpoint with background task, ingests Terraform docs only
- [ ] `/ask` endpoint: basic LCEL chain, no citations yet
- [ ] Smoke test: ingest a small fixture, ask a known-answer question, assert response is non-empty and contains expected keyword

**Acceptance criteria**: `docker compose up` brings all services healthy without manual intervention; `/ingest` successfully processes the Terraform IAM docs; `/ask` returns coherent natural-language answers grounded in the corpus.

### Phase 2 — citations + dual corpus

Goal: prove multi-source retrieval with verifiable attribution.

- [ ] Modify chain to return retrieved documents alongside the answer
- [ ] Prompt the model to cite chunks inline with `[N]` markers
- [ ] Response builder pairs `[N]` markers with chunk metadata → structured `sources` array
- [ ] Add AWS corpus ingestion (PDF loader + metadata tagging with `source: "aws"`)
- [ ] Replace single retriever with `EnsembleRetriever` over both corpora
- [ ] Refine prompt for `[TF]` vs `[AWS]` distinction
- [ ] Tests: every `/ask` response contains a non-empty `sources` array; cited chunk IDs match what the model referenced; at least one cross-source test query returns citations from both `[TF]` and `[AWS]`

**Acceptance criteria**: every `/ask` response includes a non-empty `sources` array with valid metadata; questions spanning Terraform usage and AWS service behavior return cross-referenced answers; citations are accurate (the cited chunk actually supports the claim).

### Phase 3 (optional / stretch) — retrieval quality

Goal: improve retrieval where naive top-k falls short.

- [ ] Query rewriting step before retrieval (improves vague/follow-up questions)
- [ ] Streaming responses via `.astream()` and `StreamingResponse`
- [ ] Reranker (Cohere rerank API, or local BGE reranker via sentence-transformers)
- [ ] LangSmith tracing wired in (env-var gated)
- [ ] Conversational memory for follow-up questions (`history_aware_retriever`)

**Acceptance criteria** (per sub-feature): each addition is independently toggleable and ships with a test demonstrating its effect vs. the Phase 2 baseline.

## Key Decisions & Constraints

These are deliberate choices — please respect them unless explicitly told otherwise.

1. **LCEL syntax throughout.** No `LLMChain`, `RetrievalQA`, or other legacy chain classes. Use the pipe operator and `Runnable` primitives.
2. **Embeddings are built at ingestion time, not startup.** Startup only connects to Chroma; the vector store is already populated. `/ingest` is the only place embeddings are generated for documents.
3. **Source docs stay on disk after ingestion.** Re-ingestion will happen many times during iteration; don't treat ingestion as a one-shot operation.
4. **Metadata is part of the data model**, not an afterthought. Tag everything at ingestion. Citations depend on it.
5. **Embedding model is committed.** Changing it requires full re-ingestion (vectors live in a different space). Don't swap models casually.
6. **No cloud APIs.** Ollama for everything model-related. If a feature requires a paid API, raise it explicitly before adding.
7. **Single-file artifacts where reasonable.** This is a learning project — readability > over-engineering. Don't split modules prematurely.
8. **Background tasks via FastAPI's built-in `BackgroundTasks`** for ingestion. No Celery, no Redis queue. Keep the dependency surface small.

## Common Gotchas to Watch For

- **Forgetting to `ollama pull` the models** before first run — the API will fail with model-not-found errors.
- **Chroma collection name mismatches** between ingestion and query code. Use a constant in `config.py`.
- **Re-ingesting without clearing the collection** — leads to duplicate chunks. Either delete and recreate the collection at the start of each ingest, or implement upsert with stable doc IDs.
- **Chunk size mismatch with context window** — if the LLM has an 8k context and chunks are 1000 chars, top-k=8 might exceed the window once the prompt + question are added. Math it out.
- **`docker compose down -v` wipes the volumes** — including all your embeddings. Use `docker compose down` (no `-v`) to keep data.
- **PDF loaders vary wildly in quality.** `PyPDFLoader` is fine for text PDFs; for AWS docs with complex layouts consider `UnstructuredPDFLoader` or `PyMuPDFLoader`.

## Conventions for Claude Code

- **Explain reasoning when introducing a new LangChain primitive** — the human is learning the framework, not just shipping code.
- **Prefer readable, slightly verbose code** over clever one-liners.
- **When making a design decision not covered here, surface it** before writing the code.
- **Format**: ruff for linting, black-compatible formatting, type hints throughout, Pydantic v2 for request/response models.
- **Tests** are nice-to-have, not required for v1. Focus on the happy path working end-to-end first.
