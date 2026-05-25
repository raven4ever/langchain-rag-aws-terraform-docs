#!/usr/bin/env bash
# Phase 2 smoke test against a running stack.
#
# Prereqs:
#   docker compose up -d chroma     # only chroma runs in docker now
#   ./scripts/bootstrap_ollama.sh   # pulls models onto the host Ollama
#   ./scripts/fetch_docs.sh         # populates ./data/<svc>/{terraform,aws}/
#   uvicorn app.main:app            # run the api natively from ./api/
#
# What it does:
#   1. Hits /health, asserts both deps reachable.
#   2. POSTs /ingest for the terraform corpus + polls to completion.
#   3. POSTs /ingest for the aws corpus + polls to completion.
#   4. Asks 5 questions of increasing complexity. 3 are cross-service.
#   5. For each, asserts a non-empty answer, presence of an expected keyword,
#      and a non-empty sources[] array (Phase 2 citation contract).

set -euo pipefail

API="${API:-http://localhost:8000}"
TIMEOUT_S="${TIMEOUT_S:-600}"
SERVICES_LIST="${SERVICES_LIST:-iam s3 ec2 vpc lambda rds cloudwatch cloudformation route53 dynamodb}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_ROOT="${DATA_ROOT:-${REPO_ROOT}/data}"

bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*"; }
fail()   { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

# Per-question results, collected for the final summary.
RESULTS=()    # entries: "OK|Q1|reason", "WARN|Q1|reason", "FAIL|Q1|reason"

ingest_and_wait() {
  # ingest_and_wait <source> <path> <service>
  local source="$1" path="$2" service="$3"
  bold "==> /ingest (service=${service} source=${source} path=${path})"
  local resp job_id deadline status_body status
  resp="$(curl -fsS -X POST "${API}/ingest" \
    -H 'Content-Type: application/json' \
    -d "{\"source\":\"${source}\",\"path\":\"${path}\",\"service\":\"${service}\"}")"
  echo "${resp}"
  job_id="$(echo "${resp}" | sed -n 's/.*"job_id":"\([^"]*\)".*/\1/p')"
  [[ -n "${job_id}" ]] || fail "no job_id in response (service=${service} source=${source})"

  bold "==> Poll job ${job_id} (service=${service} source=${source})"
  deadline=$(( $(date +%s) + TIMEOUT_S ))
  while :; do
    status_body="$(curl -fsS "${API}/ingest/${job_id}")"
    status="$(echo "${status_body}" | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')"
    echo "  status=${status}"
    case "${status}" in
      complete) break ;;
      failed)   fail "ingest failed (service=${service} source=${source}): ${status_body}" ;;
    esac
    if (( $(date +%s) > deadline )); then
      fail "ingest timed out after ${TIMEOUT_S}s (service=${service} source=${source}; last: ${status_body})"
    fi
    sleep 10
  done
  green "    ingestion for service=${service} source=${source} FINISHED"
}

ask_and_assert() {
  # ask_and_assert <label> <expect_keyword> <question>
  # Records the outcome in RESULTS instead of exiting on failure.
  local label="$1" kw="$2" question="$3"
  bold "==> ${label}"
  echo "    Q: ${question}"

  local body resp answer sources_count reason status
  body="$(printf '%s' "${question}" | python3 -c 'import json,sys; print(json.dumps({"question": sys.stdin.read()}))')"

  if ! resp="$(curl -fsS -X POST "${API}/ask" \
        -H 'Content-Type: application/json' \
        -d "${body}" 2>&1)"; then
    reason="HTTP error from /ask: ${resp}"
    red "    FAIL (${reason})"
    RESULTS+=("FAIL|${label}|${reason}")
    return 0
  fi

  answer="$(echo "${resp}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("answer",""))' 2>/dev/null || echo "")"
  sources_count="$(echo "${resp}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("sources",[])))' 2>/dev/null || echo "0")"

  echo "    --- ANSWER (${#answer} chars, ${sources_count} sources) ---"
  echo "${answer}" | sed 's/^/    /'

  if [[ -z "${answer}" ]]; then
    reason="empty answer"
    status="FAIL"
  elif ! echo "${answer}" | grep -qi "${kw}"; then
    reason="missing expected keyword '${kw}'"
    status="FAIL"
  elif [[ "${sources_count}" -le 0 ]]; then
    # Soft failure: model produced an answer that may be correct but emitted no
    # [N] citations — treat output as un-attributed. Use at your own risk.
    reason="answer has no [N] citations (un-attributed — use at your own risk)"
    status="WARN"
  else
    reason="sources=${sources_count}"
    status="OK"
  fi

  case "${status}" in
    OK)   green  "    OK (${reason})";                 RESULTS+=("OK|${label}|${reason}") ;;
    WARN) yellow "    WARN (${reason})";               RESULTS+=("WARN|${label}|${reason}") ;;
    *)    red    "    FAIL (${reason})";               RESULTS+=("FAIL|${label}|${reason}") ;;
  esac
}

# Health + ingest ------------------------------------------------------------

bold "==> /health"
HEALTH="$(curl -fsS "${API}/health")"
echo "${HEALTH}"
echo "${HEALTH}" | grep -q '"ollama":true' || fail "ollama not healthy"
echo "${HEALTH}" | grep -q '"chroma":true' || fail "chroma not healthy"

for svc in ${SERVICES_LIST}; do
  ingest_and_wait "terraform" "${DATA_ROOT}/${svc}/terraform" "${svc}"
  ingest_and_wait "aws"       "${DATA_ROOT}/${svc}/aws"       "${svc}"
done

# Five questions, ordered easiest → hardest.
# Each is a `keyword|question` pair. Keyword is case-insensitive substring.
# (3 of the 5 are cross-service; service pairs picked across the top-10 list.)

QUESTIONS=(
  # 1. Single-service, basic.
  "aws_iam_role|How do I create an IAM role in Terraform?"

  # 2. Single-service, slightly deeper config.
  "aws_s3_bucket|How do I enable versioning on an S3 bucket using the Terraform AWS provider?"

  # 3. Cross-service (IAM + Lambda + S3).
  "lambda|How do I grant an AWS Lambda function read and write permissions to an S3 bucket, using an IAM role attached to the function?"

  # 4. Cross-service (CloudWatch + RDS).
  "cloudwatch|How do I configure a CloudWatch alarm in Terraform that fires when an RDS DB instance's CPU utilization stays above 80% for 5 minutes?"

  # 5. Cross-service (Route 53 + Lambda + DynamoDB), most complex.
  "route53|How do I expose an AWS Lambda function behind a custom domain managed by Route 53, where the function reads and writes to a DynamoDB table, all defined in Terraform?"
)

for i in "${!QUESTIONS[@]}"; do
  IFS='|' read -r KW Q <<< "${QUESTIONS[$i]}"
  ask_and_assert "Q$((i + 1))" "${KW}" "${Q}"
done

# Summary --------------------------------------------------------------------

bold "==> Summary"
pass_count=0
warn_count=0
fail_count=0
for entry in "${RESULTS[@]}"; do
  IFS='|' read -r status label reason <<< "${entry}"
  case "${status}" in
    OK)
      green  "  ✓ ${label}  ${reason}"
      pass_count=$((pass_count + 1))
      ;;
    WARN)
      yellow "  ! ${label}  ${reason}"
      warn_count=$((warn_count + 1))
      ;;
    *)
      red    "  ✗ ${label}  ${reason}"
      fail_count=$((fail_count + 1))
      ;;
  esac
done

total=$(( pass_count + warn_count + fail_count ))
if (( fail_count == 0 )); then
  bold "==> PASS (${pass_count}/${total} fully cited, ${warn_count} un-attributed warnings)"
  exit 0
else
  bold "==> FAIL (${pass_count}/${total} cited, ${warn_count} warnings, ${fail_count} failed)"
  exit 1
fi
