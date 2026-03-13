#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="video-demo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Checking for existing cluster..."
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "    Cluster '${CLUSTER_NAME}' already exists, skipping creation."
else
  echo "==> Creating Kind cluster '${CLUSTER_NAME}'..."
  kind create cluster --name "${CLUSTER_NAME}" --config "${SCRIPT_DIR}/kind-config.yaml"
fi

echo "==> Adding Helm repos..."
helm repo add cloudnative-pg https://cloudnative-pg.github.io/charts 2>/dev/null || true
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets 2>/dev/null || true
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo add minio https://charts.min.io/ 2>/dev/null || true
helm repo update

echo "==> Installing CNPG operator..."
helm upgrade --install cnpg cloudnative-pg/cloudnative-pg \
  -n cnpg-system --create-namespace --wait

echo "==> Installing Sealed Secrets controller..."
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  -n kube-system --wait

echo "==> Creating demo namespace..."
kubectl create namespace demo --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "=== Bootstrap complete ==="
echo "  Cluster:          ${CLUSTER_NAME}"
echo "  CNPG operator:    cnpg-system"
echo "  Sealed Secrets:   kube-system"
echo "  App namespace:    demo"
echo ""
echo "  NodePort 30080 -> localhost:8082"
echo "  NodePort 30443 -> localhost:9443"
echo ""
echo "Next: Run Step 9 to install ArgoCD and seal secrets."
