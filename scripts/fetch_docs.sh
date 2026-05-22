#!/usr/bin/env bash
# Populate ./data/ with source corpora.
#
# Filters by a configurable list of AWS services. Override the default via env:
#   SERVICES="iam s3 ec2" ./scripts/fetch_docs.sh
#
# For each service the script:
#   * Copies Terraform provider docs whose filename starts with "<service>_".
#   * Downloads the AWS User Guide + API Reference PDFs (if the service appears
#     in the registry below).
#   * Restricts the CloudFormation resource spec to `AWS::<Service>::*` entries
#     using jq (falls back to the full spec if jq is missing).
#
# Idempotent: re-running refreshes everything in place.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${REPO_ROOT}/data"

SERVICES="${SERVICES:-iam s3 ec2 vpc lambda rds cloudwatch cloudformation route53 dynamodb}"

mkdir -p "${DATA_DIR}"

# AWS doc registry. Returns "user_guide_url|api_ref_url|cfn_prefix" on stdout
# given a service short-name. Exits non-zero for unknown services.
aws_urls() {
  case "$1" in
    iam)
      echo "https://docs.aws.amazon.com/IAM/latest/UserGuide/iam-ug.pdf|https://docs.aws.amazon.com/IAM/latest/APIReference/iam-api.pdf|AWS::IAM::"
      ;;
    s3)
      echo "https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-userguide.pdf|https://docs.aws.amazon.com/AmazonS3/latest/API/s3-api.pdf|AWS::S3::"
      ;;
    ec2)
      echo "https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-ug.pdf|https://docs.aws.amazon.com/AWSEC2/latest/APIReference/ec2-api.pdf|AWS::EC2::"
      ;;
    lambda)
      echo "https://docs.aws.amazon.com/lambda/latest/dg/lambda-dg.pdf|https://docs.aws.amazon.com/lambda/latest/api/lambda-api.pdf|AWS::Lambda::"
      ;;
    rds)
      echo "https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-ug.pdf|https://docs.aws.amazon.com/AmazonRDS/latest/APIReference/rds-api.pdf|AWS::RDS::"
      ;;
    vpc)
      # VPC API operations live under the EC2 API reference — reuse that URL.
      echo "https://docs.aws.amazon.com/vpc/latest/userguide/vpc-ug.pdf|https://docs.aws.amazon.com/AWSEC2/latest/APIReference/ec2-api.pdf|AWS::EC2::VPC"
      ;;
    cloudwatch)
      echo "https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/acw-ug.pdf|https://docs.aws.amazon.com/AmazonCloudWatch/latest/APIReference/acw-api.pdf|AWS::CloudWatch::"
      ;;
    cloudformation)
      echo "https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/cfn-ug.pdf|https://docs.aws.amazon.com/AWSCloudFormation/latest/APIReference/cfn-api.pdf|AWS::CloudFormation::"
      ;;
    route53)
      # Route 53 API reference is not published as a downloadable PDF; reuse the DG URL.
      echo "https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/route53-dg.pdf|https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/route53-dg.pdf|AWS::Route53::"
      ;;
    dynamodb)
      echo "https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/dynamodb-dg.pdf|https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/dynamodb-api.pdf|AWS::DynamoDB::"
      ;;
    *)
      return 1
      ;;
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

# Per-service Terraform + AWS PDF copy ---------------------------------------

echo
echo "==> Populating per-service directories"
for svc in ${SERVICES}; do
  svc_tf_dir="${DATA_DIR}/${svc}/terraform"
  svc_aws_dir="${DATA_DIR}/${svc}/aws"
  mkdir -p "${svc_tf_dir}" "${svc_aws_dir}"

  # Clean stale terraform docs so the corpus matches the current checkout.
  rm -f "${svc_tf_dir}"/*.html.markdown

  echo "  → terraform: ${svc}_*.html.markdown"
  find "${TF_CHECKOUT}/website/docs/r" -maxdepth 1 -name "${svc}_*.html.markdown" \
    -exec cp {} "${svc_tf_dir}/" \; 2>/dev/null || true
  find "${TF_CHECKOUT}/website/docs/d" -maxdepth 1 -name "${svc}_*.html.markdown" \
    -exec cp {} "${svc_tf_dir}/" \; 2>/dev/null || true

  if ! urls="$(aws_urls "${svc}")"; then
    echo "  ! no PDF registry entry for '${svc}' — skipping AWS PDFs (add a case to aws_urls() to support it)"
    continue
  fi
  IFS='|' read -r ug_url api_url _ <<< "${urls}"
  echo "  → ${svc}: user guide"
  curl -fSL -o "${svc_aws_dir}/${svc}-user-guide.pdf"    "${ug_url}"
  echo "  → ${svc}: api reference"
  curl -fSL -o "${svc_aws_dir}/${svc}-api-reference.pdf" "${api_url}"
done

# CloudFormation resource spec (filtered per service) ------------------------

CFN_SPEC_URL="https://d1uauaxba7bl26.cloudfront.net/latest/CloudFormationResourceSpecification.json"
CFN_FULL="${DATA_DIR}/.cfn-spec-full.json"

echo
echo "==> Fetching CloudFormation resource spec"
curl -fSL -o "${CFN_FULL}" "${CFN_SPEC_URL}"

if ! command -v jq >/dev/null 2>&1; then
  echo "  ! jq not installed — copying the full CFN spec into each service's aws/ dir"
  for svc in ${SERVICES}; do
    cp "${CFN_FULL}" "${DATA_DIR}/${svc}/aws/CloudFormationResourceSpecification.json"
  done
else
  for svc in ${SERVICES}; do
    if ! urls="$(aws_urls "${svc}")"; then
      continue
    fi
    IFS='|' read -r _ _ cfn_prefix <<< "${urls}"
    [[ -z "${cfn_prefix}" ]] && continue
    out="${DATA_DIR}/${svc}/aws/CloudFormationResourceSpecification.json"
    echo "  → filtering CFN spec to ${cfn_prefix}* for ${svc}"
    jq --arg prefix "${cfn_prefix}" '
      .ResourceTypes |= with_entries(select(.key | startswith($prefix))) |
      .PropertyTypes |= with_entries(select(.key | startswith($prefix)))
    ' "${CFN_FULL}" > "${out}"
  done
fi

rm -f "${CFN_FULL}"

echo
echo "==> data layout:"
for svc in ${SERVICES}; do
  printf "  data/%s/terraform/  %d files\n  data/%s/aws/  %d files\n" \
    "$svc" "$(find "${DATA_DIR}/${svc}/terraform" -maxdepth 1 -type f 2>/dev/null | wc -l)" \
    "$svc" "$(find "${DATA_DIR}/${svc}/aws" -maxdepth 1 -type f 2>/dev/null | wc -l)"
done

echo
echo "Done. Services ingested: ${SERVICES}"
