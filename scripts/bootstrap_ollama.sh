#!/usr/bin/env bash
# Pull Ollama models against the host Ollama instance.
# Prereq: Ollama installed and running on the host with OLLAMA_HOST=0.0.0.0:11434
# (so the api container can reach it via host.docker.internal).

set -euo pipefail

LLM_MODEL="${LLM_MODEL:-llama3.1:8b}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"

echo "==> Pulling ${LLM_MODEL}"
ollama pull "${LLM_MODEL}"

echo "==> Pulling ${EMBED_MODEL}"
ollama pull "${EMBED_MODEL}"

echo
echo "==> Installed models:"
ollama list
