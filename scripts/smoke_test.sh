#!/usr/bin/env bash
# Phase 2 smoke test against a running stack.
#
# Prereqs:
#   docker compose up -d
#   ./scripts/bootstrap_ollama.sh   # pulls models
#   ./scripts/fetch_docs.sh         # populates ./data/terraform/ + ./data/aws/
#
# What it does:
#   1. Hits /health, asserts both deps reachable.
#   2. POSTs /ingest for the terraform corpus + polls to completion.
#   3. POSTs /ingest for the aws corpus + polls to completion.
#   4. POSTs /ask with a cross-source question.
#   5. Asserts the answer is non-empty, contains an expected keyword, and
#      that the sources[] array is non-empty (Phase 2 citation contract).

set -euo pipefail

API="${API:-http://localhost:8000}"
TF_PATH="${TF_PATH:-../data/terraform}"
AWS_PATH="${AWS_PATH:-../data/aws}"
TIMEOUT_S="${TIMEOUT_S:-600}"
EXPECT_KEYWORD="${EXPECT_KEYWORD:-assume_role_policy}"
QUESTION="${QUESTION:-What argument on aws_iam_role sets the trust policy, and what does the AWS IAM service require it to contain?}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

ingest_and_wait() {
  local source="$1" path="$2"
  bold "==> /ingest (source=${source} path=${path})"
  local resp job_id deadline status_body status
  resp="$(curl -fsS -X POST "${API}/ingest" \
    -H 'Content-Type: application/json' \
    -d "{\"source\":\"${source}\",\"path\":\"${path}\"}")"
  echo "${resp}"
  job_id="$(echo "${resp}" | sed -n 's/.*"job_id":"\([^"]*\)".*/\1/p')"
  [[ -n "${job_id}" ]] || fail "no job_id in response (source=${source})"

  bold "==> Poll job ${job_id}"
  deadline=$(( $(date +%s) + TIMEOUT_S ))
  while :; do
    status_body="$(curl -fsS "${API}/ingest/${job_id}")"
    status="$(echo "${status_body}" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')"
    echo "  status=${status}"
    case "${status}" in
      complete) break ;;
      failed)   fail "ingest failed: ${status_body}" ;;
    esac
    if (( $(date +%s) > deadline )); then
      fail "ingest timed out after ${TIMEOUT_S}s (last: ${status_body})"
    fi
    sleep 2
  done
}

bold "==> /health"
HEALTH="$(curl -fsS "${API}/health")"
echo "${HEALTH}"
echo "${HEALTH}" | grep -q '"ollama":true' || fail "ollama not healthy"
echo "${HEALTH}" | grep -q '"chroma":true' || fail "chroma not healthy"

ingest_and_wait "terraform" "${TF_PATH}"
ingest_and_wait "aws"       "${AWS_PATH}"

bold "==> /ask"
ASK="$(curl -fsS -X POST "${API}/ask" \
  -H 'Content-Type: application/json' \
  -d "$(printf '{"question":%s}' "$(printf '%s' "${QUESTION}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")")"
echo "${ASK}"

ANSWER="$(echo "${ASK}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["answer"])')"
SOURCES_COUNT="$(echo "${ASK}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("sources",[])))')"

[[ -n "${ANSWER}" ]] || fail "empty answer"
echo "${ANSWER}" | grep -qi "${EXPECT_KEYWORD}" \
  || fail "answer missing expected keyword '${EXPECT_KEYWORD}'"
[[ "${SOURCES_COUNT}" -gt 0 ]] \
  || fail "sources[] is empty — Phase 2 expects inline citations"

bold "==> PASS (sources=${SOURCES_COUNT})"
