#!/usr/bin/env bash
# ==============================================================================
# register-repository.sh
# Registers S3 Snapshot Repositories on Amazon OpenSearch using awscurl
# ==============================================================================
set -euo pipefail

OPENSEARCH_ENDPOINT="${1:-https://search-my-opensearch-domain-xxxxxx.us-east-1.es.amazonaws.com}"
AWS_REGION="${2:-us-east-1}"
S3_BUCKET="${3:-my-opensearch-backup-bucket}"
ROLE_ARN="${4:-arn:aws:iam::123456789012:role/opensearch-s3-snapshot-role}"

echo "==> Registering Daily Snapshots Repository: daily-snapshots..."
awscurl -XPUT "${OPENSEARCH_ENDPOINT}/_snapshot/daily-snapshots" \
  --service es \
  --region "${AWS_REGION}" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "s3",
    "settings": {
      "bucket": "'"${S3_BUCKET}"'",
      "base_path": "opensearch-snapshots/prod-cluster/daily",
      "region": "'"${AWS_REGION}"'",
      "role_arn": "'"${ROLE_ARN}"'"
    }
  }'
echo ""

echo "==> Registering Application Snapshots Repository: web-portal-snapshots..."
awscurl -XPUT "${OPENSEARCH_ENDPOINT}/_snapshot/web-portal-snapshots" \
  --service es \
  --region "${AWS_REGION}" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "s3",
    "settings": {
      "bucket": "'"${S3_BUCKET}"'",
      "base_path": "opensearch-snapshots/prod-cluster/web-portal",
      "region": "'"${AWS_REGION}"'",
      "role_arn": "'"${ROLE_ARN}"'"
    }
  }'
echo ""

echo "==> Verifying all registered repositories..."
awscurl -XGET "${OPENSEARCH_ENDPOINT}/_snapshot/_all" \
  --service es \
  --region "${AWS_REGION}"
echo ""
