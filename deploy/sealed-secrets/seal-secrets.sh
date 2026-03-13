#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="demo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CNPG_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
REDIS_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
MINIO_ROOT_USER="minioadmin"
MINIO_ROOT_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
JWT_SECRET_KEY=$(openssl rand -hex 32)

echo "==> Verifying kubeseal can reach the controller..."
kubeseal --fetch-cert > /dev/null 2>&1 || {
  echo "ERROR: kubeseal cannot reach the Sealed Secrets controller."
  echo "       Make sure the Kind cluster is running and bootstrap.sh has been executed."
  exit 1
}

seal_secret() {
  local name="$1"
  local output="$2"
  shift 2

  local args=()
  while [[ $# -gt 0 ]]; do
    args+=("--from-literal=$1")
    shift
  done

  echo "    Sealing ${name}..."
  kubectl create secret generic "${name}" \
    --namespace "${NAMESPACE}" \
    --dry-run=client -o yaml \
    "${args[@]}" \
    | kubeseal --format yaml \
    > "${output}"
}

echo "==> Sealing infrastructure secrets..."

seal_secret "cnpg-app-creds" "${SCRIPT_DIR}/cnpg-app-creds.yaml" \
  "username=app" \
  "password=${CNPG_PASSWORD}"

seal_secret "redis-password" "${SCRIPT_DIR}/redis-password.yaml" \
  "redis-password=${REDIS_PASSWORD}"

seal_secret "minio-creds" "${SCRIPT_DIR}/minio-creds.yaml" \
  "rootUser=${MINIO_ROOT_USER}" \
  "rootPassword=${MINIO_ROOT_PASSWORD}"

echo "==> Sealing application shared secrets..."

DB_URL="postgres://app:${CNPG_PASSWORD}@demo-pg-rw:5432/demo"
REDIS_URL="redis://:${REDIS_PASSWORD}@demo-redis-master:6379/0"
CELERY_BROKER="redis://:${REDIS_PASSWORD}@demo-redis-master:6379/1"

seal_secret "app-shared-secrets" "${SCRIPT_DIR}/app-shared-secrets.yaml" \
  "DATABASE_URL=${DB_URL}" \
  "REDIS_URL=${REDIS_URL}" \
  "CELERY_BROKER_URL=${CELERY_BROKER}" \
  "MINIO_ENDPOINT=demo-minio:9000" \
  "MINIO_ACCESS_KEY=${MINIO_ROOT_USER}" \
  "MINIO_SECRET_KEY=${MINIO_ROOT_PASSWORD}"

echo "==> Sealing API-only secrets..."

seal_secret "app-api-secrets" "${SCRIPT_DIR}/app-api-secrets.yaml" \
  "JWT_SECRET_KEY=${JWT_SECRET_KEY}"

echo "==> Creating GHCR pull secret..."
if [[ -z "${GHCR_TOKEN:-}" ]]; then
  echo "    WARNING: GHCR_TOKEN not set. Skipping ghcr-pull-secret."
  echo "    To create it later, run:"
  echo "      kubectl create secret docker-registry ghcr-pull-secret \\"
  echo "        --namespace ${NAMESPACE} \\"
  echo "        --docker-server=ghcr.io \\"
  echo "        --docker-username=<github-username> \\"
  echo "        --docker-password=<github-pat>"
else
  echo "    Creating ghcr-pull-secret..."
  kubectl create secret docker-registry ghcr-pull-secret \
    --namespace "${NAMESPACE}" \
    --docker-server=ghcr.io \
    --docker-username="${GHCR_USER:-GiladTrachtenberg}" \
    --docker-password="${GHCR_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

echo ""
echo "=== Sealed secrets written ==="
echo "  ${SCRIPT_DIR}/cnpg-app-creds.yaml"
echo "  ${SCRIPT_DIR}/redis-password.yaml"
echo "  ${SCRIPT_DIR}/minio-creds.yaml"
echo "  ${SCRIPT_DIR}/app-shared-secrets.yaml"
echo "  ${SCRIPT_DIR}/app-api-secrets.yaml"
echo ""
echo "Apply with: kubectl apply -f ${SCRIPT_DIR}/"
echo ""
echo "NOTE: These sealed values are bound to THIS cluster's key."
echo "      If you recreate the cluster, re-run this script."
