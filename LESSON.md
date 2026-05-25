# Lesson: How TerraSage Works

This document explains the application from end to end for someone who has never touched LangChain or RAG before.
Each section links into the actual code so you can follow along.

## 1. The big idea: Retrieval-Augmented Generation (RAG)

A large language model (LLM) like Llama 3.1 was trained on text from the public internet up to some cutoff date.
Ask it a question about your private docs, your company wiki, or a recent piece of documentation and it will either say "I don't know" or — worse — confidently make something up (this is called **hallucination**).

**RAG** fixes that by doing two things at query time:

1. **Retrieve** the most relevant pieces of _your_ documents from a database.
2. **Augment** the LLM's prompt with those pieces, and ask it to answer using only the supplied context.

The LLM still does the writing, but its facts now come from documents you control, not from its training memory.
That makes answers up-to-date, attributable (you can cite the exact chunk), and grounded in your domain.

TerraSage applies this pattern to two corpora at once: the **Terraform AWS provider docs** (how do I configure this in HCL?) and the **AWS service docs** (what does this AWS feature actually do?).
The user gets answers that mix provider-specific syntax with authoritative AWS semantics, and each fact is linked back to a source.

## 2. The moving parts

Three processes talk to each other:

| Component  | What it is                                                               | Where it runs                  |
| ---------- | ------------------------------------------------------------------------ | ------------------------------ |
| **API**    | FastAPI app — exposes `/ingest`, `/ask`, `/health`                       | Native Python on your host     |
| **Chroma** | Vector database — stores text chunks + their embeddings                  | Docker container               |
| **Ollama** | Local LLM + embedding server — runs `llama3.1:8b` and `nomic-embed-text` | Native on your host (uses GPU) |

The API process orchestrates everything: it ingests docs into Chroma, retrieves relevant chunks at query time, talks to Ollama for both embeddings and the final answer, and returns the result to the user.

Bootstrap path:

- API entrypoint and route registration: [`api/app/main.py:12`](api/app/main.py#L12)
- Settings (env-driven config): [`Settings` in `api/app/config.py:6`](api/app/config.py#L6)
- Shared client objects (Chroma, Ollama, vectorstore, LLM): [`api/app/deps.py:10`](api/app/deps.py#L10)

The `@lru_cache(maxsize=1)` decorator on each `get_*` function in `deps.py` means the client is built **once per process** and reused on every request.
Building a Chroma client or loading an LLM connection isn't free — caching it keeps each `/ask` call cheap.

## 3. Vocabulary you need (with code anchors)

- **Document** — a single piece of text with metadata (filename, page, source).
  In LangChain it's literally [`langchain_core.documents.Document`](https://python.langchain.com/api_reference/core/documents/langchain_core.documents.base.Document.html).
  You see it everywhere — loaders produce them, the splitter takes them in and emits more of them, the retriever returns them.

- **Chunk** — a Document after the splitter has cut it into LLM-friendly sizes.
  Same type, just smaller `page_content`.

- **Embedding** — a list of floating-point numbers (768 of them for `nomic-embed-text`) that represents the _meaning_ of a piece of text.
  Two chunks with similar meaning produce similar vectors.
  The embedding model ([`OllamaEmbeddings` in deps.py:18](api/app/deps.py#L18)) is what turns text into these vectors.

- **Vector store** — a database that holds vectors and lets you ask "give me the K vectors closest to this query vector."
  Here it's Chroma, wrapped by LangChain's [`Chroma` adapter in deps.py:25](api/app/deps.py#L25).

- **Retriever** — a small object that takes a question string, embeds it, searches the vector store, and returns the top-K Documents.
  Wired up in [`build_retriever` in retriever.py:18](api/app/rag/retriever.py#L18).

- **LCEL (LangChain Expression Language)** — LangChain's pipe-syntax for composing steps.
  You'll see expressions like `retriever | format_context | prompt | llm | parser`.
  Each `|` means "pass the output of the left side as input to the right."
  The chain that powers `/ask` lives in [`build_chain` in chain.py:37](api/app/rag/chain.py#L37).

- **Prompt template** — a string with placeholders that LangChain fills in before sending to the LLM.
  Our system prompt lives in [`SYSTEM_PROMPT` in prompts.py:5](api/app/rag/prompts.py#L5); the full template (system + human) is the [`ASK_PROMPT` constant at prompts.py:28](api/app/rag/prompts.py#L28).

## 4. Phase A: Ingestion (`POST /ingest`)

Ingestion is the offline step where your source documents become searchable vectors.
You run it once per corpus, then again whenever the docs change.

### 4.1 The request

[`POST /ingest` route in api/ingest.py:13](api/app/api/ingest.py#L13) accepts:

```json
{ "source": "terraform", "path": "./data/iam/terraform", "service": "iam" }
```

`source` is either `"terraform"` or `"aws"` (the [`SourceName` literal in models.py:6](api/app/models.py#L6)).
`service` is a label that gets attached to every chunk's metadata so we can filter retrieval later.

The route creates a job record and schedules a background task; it returns immediately with a `job_id` so the caller can poll status without blocking on a multi-minute embed loop.
The job runner is [`run_ingest` in pipeline.py:60](api/app/ingestion/pipeline.py#L60).

### 4.2 Load

Each source has a loader function:

- [`load_terraform` in loaders.py:20](api/app/ingestion/loaders.py#L20) — reads every `*.html.markdown` / `*.md` file in the directory using [`TextLoader`](https://python.langchain.com/api_reference/community/document_loaders/langchain_community.document_loaders.text.TextLoader.html), then tags each Document with `source="terraform"`, `service`, `doc_id`, and (when the filename matches `aws_<resource>.html.markdown`) `resource_type`.

- [`load_aws` in loaders.py:49](api/app/ingestion/loaders.py#L49) — reads PDFs via [`PyMuPDFLoader`](https://python.langchain.com/api_reference/community/document_loaders/langchain_community.document_loaders.pdf.PyMuPDFLoader.html) (one Document per page, with a `page` field already in metadata).

The two loaders are registered in a tiny dispatch table [`_LOADERS` in pipeline.py:25](api/app/ingestion/pipeline.py#L25), so adding a new source (say `gcp`) is just one more entry.

**Metadata is load-bearing.** Every chunk carries `source`, `service`, `doc_id`, and optionally `page` and `resource_type`.
Retrieval filters (section 5.2) and citations (section 5.5) depend on those fields surviving the splitter and ending up in Chroma.

### 4.3 Split

LLMs have a finite context window.
Even llama3.1's ~128k token capacity shrinks fast once you also pack the question, the system prompt, and several chunks.
You want each chunk to be small enough that 4-8 of them fit comfortably, but big enough to carry coherent meaning.

[`split_documents` in splitter.py:7](api/app/ingestion/splitter.py#L7) uses LangChain's [`RecursiveCharacterTextSplitter`](https://python.langchain.com/api_reference/text_splitters/character/langchain_text_splitters.character.RecursiveCharacterTextSplitter.html) with a list of preferred separators (`"\n## "`, `"\n### "`, `"\n\n"`, `"\n"`, `" "`, `""`).
The splitter tries to cut at the strongest separator first — heading boundaries, then paragraphs — falling back to character-level cuts only as a last resort.
That keeps chunk boundaries semantically clean.

Each chunk inherits the parent Document's metadata, so the `source` / `service` / `doc_id` tags from the loader propagate to every chunk.

### 4.4 Embed and store

Once chunks exist, [`run_ingest` (pipeline.py:60)](api/app/ingestion/pipeline.py#L60) hands them to the vector store:

```python
ids = [f"{source}::{doc_id}::{i}" for i, c in enumerate(chunks)]
vs.add_documents(chunks[start:end], ids=ids[start:end])
```

Internally that does three things:

1. Calls the embedding model ([`OllamaEmbeddings` in deps.py:18](api/app/deps.py#L18)) to turn each chunk's text into a 768-float vector.
2. Sends the chunks + vectors + metadata to Chroma in one HTTP POST.
3. Because we pass explicit `ids` (a stable string per chunk), Chroma **upserts**: re-ingesting the same docs updates rows in place instead of appending duplicates.

There is a real-world wrinkle here: each request body to Chroma must stay under an HTTP payload cap.
The code computes a safe `batch_size` from the embedding dimensionality (`per_chunk_bytes = chunk_size + embed_dim * 12 + 512`) and slices the upsert into batches inside the loop in [pipeline.py:114](api/app/ingestion/pipeline.py#L114).
Every batch logs a progress line so you can watch ingestion advance.

### 4.5 Polling

[`GET /ingest/{job_id}` in ingest.py:21](api/app/api/ingest.py#L21) returns the current status: `pending` → `running` → `complete` or `failed`.
The job state lives in a process-local dict ([`_jobs` in pipeline.py:21](api/app/ingestion/pipeline.py#L21)) protected by a lock.
That's fine for the single-process setup here; a multi-replica deployment would need a real queue.

## 5. Phase B: Asking a question (`POST /ask`)

Once chunks live in Chroma, you can ask questions.

### 5.1 The request

[`POST /ask` route in ask.py:46](api/app/api/ask.py#L46) accepts a question string and runs it through the RAG chain.

### 5.2 Retrieval

[`build_retriever` in retriever.py:18](api/app/rag/retriever.py#L18) builds an [`EnsembleRetriever`](https://python.langchain.com/api_reference/classic/retrievers/langchain_classic.retrievers.ensemble.EnsembleRetriever.html) composed of two **subset retrievers** — one filtered to `source="terraform"`, one filtered to `source="aws"`, both backed by the same Chroma collection:

```python
tf  = vectorstore.as_retriever(search_kwargs={"k": k, "filter": {"source": "terraform"}})
aws = vectorstore.as_retriever(search_kwargs={"k": k, "filter": {"source": "aws"}})
return EnsembleRetriever(retrievers=[tf, aws], weights=[0.5, 0.5])
```

The split-then-merge strategy guarantees that the LLM receives chunks from BOTH corpora, not just whichever happens to score higher for a given question.
That's how cross-source citations (`[1]` from a TF doc, `[2]` from an AWS guide) become possible.

Each subset retriever uses Chroma's `filter` argument, which is why **metadata tagging at ingestion time matters** (section 4.2).
Without `source` on each chunk, this filter would be empty.

### 5.3 Formatting the context

The LLM doesn't see Documents directly — it sees a string.
The code in [`_format_context` (chain.py:26)](api/app/rag/chain.py#L26) walks the list of retrieved chunks and renders something like:

```
[1] [TF: iam_role.html.markdown]
resource "aws_iam_role" "example" { ... assume_role_policy = ... }

[2] [AWS: iam-user-guide.pdf p.42]
A trust policy specifies which principals can assume the role...
```

The numeric `[N]` prefix is what the model will be asked to cite.
The `[TF: ...]` / `[AWS: ... p.42]` tag is rendered by [`_source_tag` in chain.py:15](api/app/rag/chain.py#L15) and tells the model which corpus each chunk came from.

### 5.4 The LCEL chain

Here's where LangChain's pipe syntax pays off.
The full chain assembly is [`build_chain` in chain.py:37](api/app/rag/chain.py#L37):

```python
return (
    {"question": RunnablePassthrough(), "docs": retrieve}
    | RunnablePassthrough.assign(answer=answer_chain)
    | (lambda x: {"answer": x["answer"], "docs": x["docs"]})
)
```

Read it as three stages:

1. The input is a question string.
   `RunnablePassthrough` forwards it under the key `"question"`; the retriever runs in parallel under the key `"docs"`.
   Output of stage 1 is a dict `{question, docs}`.

2. `RunnablePassthrough.assign(answer=answer_chain)` runs the inner `answer_chain` (prompt → LLM → string parser) over the dict and adds the model's text answer under `"answer"`.
   The dict now has `{question, docs, answer}`.

3. The final lambda drops the question and returns `{answer, docs}` to the caller.

The trick is that the **docs are retrieved once and kept alive through the whole chain**.
Stage 2 uses them to build the prompt context; stage 3 returns them so the route can map citations back to chunks.

If LCEL feels unfamiliar, the mental model is just function composition with syntactic sugar:

- `a | b` ≡ `b(a(x))` for runnable `a` and `b`
- A dict like `{"k": fn}` is shorthand for "build a dict whose value at `k` is `fn(input)`"
- [`RunnablePassthrough()`](https://python.langchain.com/api_reference/core/runnables/langchain_core.runnables.passthrough.RunnablePassthrough.html) means "forward my input unchanged"

### 5.5 Citations: turning `[N]` markers into a `sources[]` array

The LLM is instructed (by [`SYSTEM_PROMPT` in prompts.py:5](api/app/rag/prompts.py#L5)) to cite every factual claim with an inline `[N]` marker.
The N matches the 1-indexed number that `_format_context` printed in the prompt.

After the chain runs, [`_build_sources` in ask.py:20](api/app/api/ask.py#L20) parses the answer string with a regex ([`_CITE_RE` at ask.py:16](api/app/api/ask.py#L16): `re.compile(r"\[(\d+)\]")`), de-duplicates the citations in order of first appearance, and pairs each N with the metadata of `docs[N-1]`.
The route then returns:

```json
{
  "answer": "Use `assume_role_policy` [1]. AWS requires the trust policy to specify a principal [2]...",
  "sources": [
    {
      "id": 1,
      "source": "terraform",
      "doc_id": "iam_role.html.markdown",
      "page": null,
      "snippet": "..."
    },
    {
      "id": 2,
      "source": "aws",
      "doc_id": "iam-user-guide.pdf",
      "page": 42,
      "snippet": "..."
    }
  ]
}
```

The end-to-end guarantee: every `[N]` in `answer` is reachable in the `sources[]` array, and every `sources` entry points to a real chunk in Chroma.
That's how the user audits an answer.

When the LLM forgets to emit any `[N]` markers (smaller models do this under heavy cross-domain synthesis pressure), `sources[]` comes back empty.
The smoke test treats this as a **warning**, not a failure — the answer may still be correct, but it's un-attributed and should be treated with caution.

## 6. Health and observability

[`GET /health`](api/app/api/health.py#L44) returns a tiny status struct: whether Ollama answered an `/api/tags` call, whether Chroma responded to a `heartbeat()`, and how many chunks are currently in the collection.
It's what the smoke test asserts at startup and what you should curl after every bring-up.

Ingestion logs (look for `STARTED` / `loading` / `split` / `batched` / `FINISHED` markers) tell you which stage a job is in.
The wall-time gap between `split` and the first `batched` is your embed throughput; the gap between consecutive `batched` lines is the steady-state ingest speed.

## 7. A mental model to take away

You can think of TerraSage as **one big function**:

```
question  →  retrieve_top_K_chunks(question)
          →  render_chunks_as_numbered_context(chunks)
          →  ask_llm(system_prompt + context + question)
          →  parse_[N]_markers_back_into_chunk_metadata
          →  { answer, sources }
```

Every file in `api/app/` plays a small, named role inside that flow:

- `loaders.py` + `splitter.py` + `pipeline.py` populate the database that `retrieve_top_K_chunks` searches.
- `retriever.py` is `retrieve_top_K_chunks`.
- `chain.py` is `render_chunks_as_numbered_context` and `ask_llm`.
- `prompts.py` is the instructions packaged with every LLM call.
- `ask.py` is `parse_[N]_markers_back_into_chunk_metadata`.
- `deps.py` is the wiring that gives every step access to the same Chroma client, the same LLM connection, and the same embedding model.

Once you internalize that shape, the rest of LangChain stops looking like magic — it's just a kit of small, composable pieces wired together with `|`.
