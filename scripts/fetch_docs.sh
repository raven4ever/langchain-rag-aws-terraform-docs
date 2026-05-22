#!/usr/bin/env bash
# Populate ./data/ with source corpora.
#
# Filters by a configurable list of AWS services. Override the default via env:
#   SERVICES="iam s3 ec2" ./scripts/fetch_docs.sh
#
# For each service the script:
#   * Copies Terraform provider docs whose filename starts with "<service>_".
#   * Downloads the AWS User Guide PDF (prose-heavy: behavior, constraints).
#   * Downloads the AWS API Reference PDF (parameter names + types — used to
#     bridge Terraform argument names ↔ AWS API parameter names).
#
# The CloudFormation resource specification is intentionally NOT fetched: it is
# structured JSON that embeds poorly for natural-language Q&A.
#
# Idempotent: re-running refreshes everything in place.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${REPO_ROOT}/data"

SERVICES="${SERVICES:-iam s3 ec2 vpc lambda rds cloudwatch cloudformation route53 dynamodb}"

mkdir -p "${DATA_DIR}"

# AWS doc registry. Returns "user_guide_url|api_reference_url" on stdout.
# Use "-" for api_reference_url when the API ref is not published as a PDF.
# Exits non-zero for unknown services so the loop can warn and continue.
aws_urls() {
  case "$1" in
    iam)            echo "https://docs.aws.amazon.com/IAM/latest/UserGuide/iam-ug.pdf|https://docs.aws.amazon.com/IAM/latest/APIReference/iam-api.pdf" ;;
    s3)             echo "https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-userguide.pdf|https://docs.aws.amazon.com/AmazonS3/latest/API/s3-api.pdf" ;;
    ec2)            echo "https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-ug.pdf|https://docs.aws.amazon.com/AWSEC2/latest/APIReference/ec2-api.pdf" ;;
    lambda)         echo "https://docs.aws.amazon.com/lambda/latest/dg/lambda-dg.pdf|https://docs.aws.amazon.com/lambda/latest/api/lambda-api.pdf" ;;
    rds)            echo "https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-ug.pdf|https://docs.aws.amazon.com/AmazonRDS/latest/APIReference/rds-api.pdf" ;;
    # VPC API operations live under the EC2 API reference.
    vpc)            echo "https://docs.aws.amazon.com/vpc/latest/userguide/vpc-ug.pdf|https://docs.aws.amazon.com/AWSEC2/latest/APIReference/ec2-api.pdf" ;;
    cloudwatch)     echo "https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/acw-ug.pdf|https://docs.aws.amazon.com/AmazonCloudWatch/latest/APIReference/acw-api.pdf" ;;
    cloudformation) echo "https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/cfn-ug.pdf|https://docs.aws.amazon.com/AWSCloudFormation/latest/APIReference/cfn-api.pdf" ;;
    # Route 53 API reference is not published as a downloadable PDF.
    route53)        echo "https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/route53-dg.pdf|-" ;;
    dynamodb)       echo "https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/dynamodb-dg.pdf|https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/dynamodb-api.pdf" ;;
    *)              return 1 ;;
  esac
}

# Terraform docs -------------------------------------------------------------

TF_REPO="https://github.com/hashicorp/terraform-provider-aws.git"
TF_CHECKOUT="${DATA_DIR}/.tf_checkout"

echo "==> Sparse-checking out Terraform AWS provider docs"
if [[ -d "${TF_CHECKOUT}/.git" ]]; then
  git -C "${TF_CHECKOUT}" fetch --depth=1 origin main
  git -C "${TF_CHECKOUT}" reset --hard origin/main
else
  git clone --depth=1 --filter=blob:none --sparse "${TF_REPO}" "${TF_CHECKOUT}"
  git -C "${TF_CHECKOUT}" sparse-checkout set website/docs/r website/docs/d
fi

# Per-service Terraform + AWS User Guide ------------------------------------

echo
echo "==> Populating per-service directories"
for svc in ${SERVICES}; do
  svc_tf_dir="${DATA_DIR}/${svc}/terraform"
  svc_aws_dir="${DATA_DIR}/${svc}/aws"
  mkdir -p "${svc_tf_dir}" "${svc_aws_dir}"

  # Wipe stale corpora so the layout matches the current run.
  rm -f "${svc_tf_dir}"/*.html.markdown
  rm -f "${svc_aws_dir}"/*.pdf "${svc_aws_dir}"/*.json

  echo "  → terraform: ${svc}_*.html.markdown"
  find "${TF_CHECKOUT}/website/docs/r" -maxdepth 1 -name "${svc}_*.html.markdown" \
    -exec cp {} "${svc_tf_dir}/" \; 2>/dev/null || true
  find "${TF_CHECKOUT}/website/docs/d" -maxdepth 1 -name "${svc}_*.html.markdown" \
    -exec cp {} "${svc_tf_dir}/" \; 2>/dev/null || true

  if ! urls="$(aws_urls "${svc}")"; then
    echo "  ! no registry entry for '${svc}' — skipping AWS PDFs (add a case to aws_urls() to support it)"
    continue
  fi
  IFS='|' read -r ug_url api_url <<< "${urls}"
  echo "  → ${svc}: user guide"
  curl -fSL -o "${svc_aws_dir}/${svc}-user-guide.pdf" "${ug_url}"
  if [[ "${api_url}" != "-" ]]; then
    echo "  → ${svc}: api reference"
    curl -fSL -o "${svc_aws_dir}/${svc}-api-reference.pdf" "${api_url}"
  else
    echo "  → ${svc}: no API reference PDF published — skipped"
  fi
done

echo
echo "==> data layout:"
for svc in ${SERVICES}; do
  printf "  data/%s/terraform/  %d files\n  data/%s/aws/  %d files\n" \
    "$svc" "$(find "${DATA_DIR}/${svc}/terraform" -maxdepth 1 -type f 2>/dev/null | wc -l)" \
    "$svc" "$(find "${DATA_DIR}/${svc}/aws" -maxdepth 1 -type f 2>/dev/null | wc -l)"
done

echo
echo "Done. Services ingested: ${SERVICES}"
