#!/usr/bin/env bash
# Populate ./data/ with source corpora.
#
# Phase 1: Terraform AWS provider IAM markdown docs (sparse-checkout).
# Phase 2: AWS IAM User Guide PDF + API reference + CFN spec (placeholders below).
#
# Idempotent: re-running refreshes Terraform docs in place.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${REPO_ROOT}/data"
TF_DIR="${DATA_DIR}/terraform"
AWS_DIR="${DATA_DIR}/aws"

mkdir -p "${TF_DIR}" "${AWS_DIR}"

TF_REPO="https://github.com/hashicorp/terraform-provider-aws.git"
TF_CHECKOUT="${DATA_DIR}/.tf_checkout"

echo "==> Fetching Terraform AWS provider IAM docs"
if [[ -d "${TF_CHECKOUT}/.git" ]]; then
  git -C "${TF_CHECKOUT}" fetch --depth=1 origin main
  git -C "${TF_CHECKOUT}" reset --hard origin/main
else
  git clone --depth=1 --filter=blob:none --sparse "${TF_REPO}" "${TF_CHECKOUT}"
  git -C "${TF_CHECKOUT}" sparse-checkout set website/docs/r website/docs/d
fi

# Copy only IAM resource + data-source markdown into ./data/terraform/
rm -f "${TF_DIR}"/iam_*.html.markdown
find "${TF_CHECKOUT}/website/docs/r" -maxdepth 1 -name 'iam_*.html.markdown' \
  -exec cp {} "${TF_DIR}/" \;
find "${TF_CHECKOUT}/website/docs/d" -maxdepth 1 -name 'iam_*.html.markdown' \
  -exec cp {} "${TF_DIR}/" \;

echo "==> Terraform IAM docs in ${TF_DIR}:"
ls "${TF_DIR}" | head

echo
echo "==> AWS corpus (Phase 2) — placeholder."
echo "    Drop the following into ${AWS_DIR}/ when ready:"
echo "      - iam-user-guide.pdf  (AWS IAM User Guide)"
echo "      - iam-api-reference.pdf  (AWS IAM API Reference)"
echo "      - CloudFormationResourceSpecification.json  (CFN spec)"
echo
echo "Done."
