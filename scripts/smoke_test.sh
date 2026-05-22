#!/usr/bin/env bash
# Phase 1 smoke test against a running stack.
#
# Prereqs:
#   docker compose up -d
#   ./scripts/bootstrap_ollama.sh   # pulls models
#
# What it does:
#   1. Hits /health, asserts both deps reachable.
#   2. POSTs /ingest pointing at the test fixture (mounted via docker-compose).
#   3. Polls /ingest/{job_id} until complete (or timeout).
#   4. POSTs /ask with a known-answer question.
#   5. Asserts the answer is non-empty and contains an expected keyword.

set -euo pipefail

API="${API:-http://localhost:8000}"
FIXTURE_PATH="${FIXTURE_PATH:-/app/tests/fixtures/terraform}"
TIMEOUT_S="${TIMEOUT_S:-180}"
EXPECT_KEYWORD="${EXPECT_KEYWORD:-assume_role_policy}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

bold "==> /health"
HEALTH="$(curl -fsS "${API}/health")"
echo "${HEALTH}"
echo "${HEALTH}" | grep -q '"ollama":true' || fail "ollama not healthy"
echo "${HEALTH}" | grep -q '"chroma":true' || fail "chroma not healthy"

bold "==> /ingest (source=terraform path=${FIXTURE_PATH})"
INGEST="$(curl -fsS -X POST "${API}/ingest" \
  -H 'Content-Type: application/json' \
  -d "{\"source\":\"terraform\",\"path\":\"${FIXTURE_PATH}\"}")"
echo "${INGEST}"
JOB_ID="$(echo "${INGEST}" | sed -n 's/.*"job_id":"\([^"]*\)".*/\1/p')"
[[ -n "${JOB_ID}" ]] || fail "no job_id in response"

bold "==> Poll job ${JOB_ID}"
DEADLINE=$(( $(date +%s) + TIMEOUT_S ))
while :; do
  STATUS_BODY="$(curl -fsS "${API}/ingest/${JOB_ID}")"
  STATUS="$(echo "${STATUS_BODY}" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')"
  echo "  status=${STATUS}"
  case "${STATUS}" in
    complete) break ;;
    failed)   fail "ingest failed: ${STATUS_BODY}" ;;
  esac
  if (( $(date +%s) > DEADLINE )); then
    fail "ingest timed out after ${TIMEOUT_S}s (last: ${STATUS_BODY})"
  fi
  sleep 2
done

bold "==> /ask"
ASK="$(curl -fsS -X POST "${API}/ask" \
  -H 'Content-Type: application/json' \
  -d '{"question":"What argument on aws_iam_role sets the trust policy?"}')"
echo "${ASK}"
ANSWER="$(echo "${ASK}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["answer"])')"
[[ -n "${ANSWER}" ]] || fail "empty answer"
echo "${ANSWER}" | grep -qi "${EXPECT_KEYWORD}" \
  || fail "answer missing expected keyword '${EXPECT_KEYWORD}'"

bold "==> PASS"
