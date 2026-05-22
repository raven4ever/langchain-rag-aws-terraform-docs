#!/usr/bin/env bash
# Pull Ollama models inside the running ollama container.
# Run after `docker compose up -d ollama`.

set -euo pipefail

LLM_MODEL="${LLM_MODEL:-llama3.1:8b}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"
CONTAINER="${OLLAMA_CONTAINER:-rag-ollama}"

echo "==> Pulling ${LLM_MODEL}"
docker exec "${CONTAINER}" ollama pull "${LLM_MODEL}"

echo "==> Pulling ${EMBED_MODEL}"
docker exec "${CONTAINER}" ollama pull "${EMBED_MODEL}"

echo
echo "==> Installed models:"
docker exec "${CONTAINER}" ollama list
