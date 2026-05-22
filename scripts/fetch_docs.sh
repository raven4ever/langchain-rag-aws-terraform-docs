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
TF_DIR="${DATA_DIR}/terraform"
AWS_DIR="${DATA_DIR}/aws"

SERVICES="${SERVICES:-iam s3 ec2 vpc lambda rds cloudwatch cloudformation route53 dynamodb}"

mkdir -p "${TF_DIR}" "${AWS_DIR}"

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

# Wipe old terraform docs to keep the corpus matching the current SERVICES list.
rm -f "${TF_DIR}"/*.html.markdown
for svc in ${SERVICES}; do
  echo "  → terraform: ${svc}_*.html.markdown"
  find "${TF_CHECKOUT}/website/docs/r" -maxdepth 1 -name "${svc}_*.html.markdown" \
    -exec cp {} "${TF_DIR}/" \; 2>/dev/null || true
  find "${TF_CHECKOUT}/website/docs/d" -maxdepth 1 -name "${svc}_*.html.markdown" \
    -exec cp {} "${TF_DIR}/" \; 2>/dev/null || true
done

echo "==> Terraform docs in ${TF_DIR}:"
ls "${TF_DIR}" | head

# AWS PDFs -------------------------------------------------------------------

echo
echo "==> Fetching AWS service PDFs"
for svc in ${SERVICES}; do
  if ! urls="$(aws_urls "${svc}")"; then
    echo "  ! no PDF registry entry for '${svc}' — skipping (add a case to aws_urls() to support it)"
    continue
  fi
  IFS='|' read -r ug_url api_url _ <<< "${urls}"
  echo "  → ${svc}: user guide"
  curl -fSL -o "${AWS_DIR}/${svc}-user-guide.pdf"    "${ug_url}"
  echo "  → ${svc}: api reference"
  curl -fSL -o "${AWS_DIR}/${svc}-api-reference.pdf" "${api_url}"
done

# CloudFormation resource spec (filtered to selected services) ---------------

CFN_SPEC_URL="https://d1uauaxba7bl26.cloudfront.net/latest/CloudFormationResourceSpecification.json"
CFN_FULL="${AWS_DIR}/.cfn-spec-full.json"
CFN_OUT="${AWS_DIR}/CloudFormationResourceSpecification.json"

echo
echo "==> Fetching CloudFormation resource spec"
curl -fSL -o "${CFN_FULL}" "${CFN_SPEC_URL}"

# Build the prefix list from the registry.
PREFIXES=()
for svc in ${SERVICES}; do
  if urls="$(aws_urls "${svc}")"; then
    IFS='|' read -r _ _ cfn_prefix <<< "${urls}"
    [[ -n "${cfn_prefix}" ]] && PREFIXES+=("${cfn_prefix}")
  fi
done

if ! command -v jq >/dev/null 2>&1; then
  echo "  ! jq not installed — keeping the full CFN spec (all AWS services)"
  mv "${CFN_FULL}" "${CFN_OUT}"
elif [[ ${#PREFIXES[@]} -eq 0 ]]; then
  echo "  ! no known CFN prefixes for SERVICES='${SERVICES}' — keeping full spec"
  mv "${CFN_FULL}" "${CFN_OUT}"
else
  echo "  → filtering CFN spec to prefixes: ${PREFIXES[*]}"
  PREFIX_JSON="$(printf '%s\n' "${PREFIXES[@]}" | jq -R . | jq -s .)"
  jq --argjson prefixes "${PREFIX_JSON}" '
    .ResourceTypes |= with_entries(select([.key | startswith($prefixes[])] | any)) |
    .PropertyTypes |= with_entries(select([.key | startswith($prefixes[])] | any))
  ' "${CFN_FULL}" > "${CFN_OUT}"
  rm -f "${CFN_FULL}"
fi

echo "==> AWS docs in ${AWS_DIR}:"
ls -lh "${AWS_DIR}"

echo
echo "Done. Services ingested: ${SERVICES}"
