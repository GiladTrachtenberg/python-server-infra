#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="video-demo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEALED_DIR="${SCRIPT_DIR}/../sealed-secrets"

if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Cluster '${CLUSTER_NAME}' does not exist. Nothing to do."
  exit 0
fi

echo "==> Deleting Kind cluster '${CLUSTER_NAME}'..."
kind delete cluster --name "${CLUSTER_NAME}"

echo "==> Cleaning generated sealed secret files..."
rm -f "${SEALED_DIR}"/*.yaml

echo "=== Teardown complete ==="
