#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="video-demo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ensure_tool() {
  local cmd="$1"
  local brew_name="${2:-$1}"

  if command -v "$cmd" &>/dev/null; then
    echo "    $cmd: $(command -v "$cmd")"
    return
  fi

  if ! command -v brew &>/dev/null; then
    echo "ERROR: $cmd not found and brew is not available."
    echo "       Install $cmd manually: https://formulae.brew.sh/formula/$brew_name"
    exit 1
  fi

  read -rp "    $cmd not found. Install via Homebrew? [y/N] " answer
  if [[ "${answer,,}" == "y" ]]; then
    brew install "$brew_name"
  else
    echo "ERROR: $cmd is required. Aborting."
    exit 1
  fi
}

echo "==> Checking prerequisites..."
ensure_tool kind
ensure_tool helm
ensure_tool kubectl kubernetes-cli
ensure_tool kubeseal
ensure_tool jq
ensure_tool docker

if ! docker info &>/dev/null; then
  echo "ERROR: Docker is installed but not running. Start Docker Desktop and retry."
  exit 1
fi
echo "    Docker daemon: running"

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
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update

echo "==> Installing CNPG operator..."
helm upgrade --install cnpg cloudnative-pg/cloudnative-pg \
  -n cnpg-system --create-namespace --wait

echo "==> Installing Sealed Secrets controller..."
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  -n kube-system --wait

echo "==> Installing ArgoCD..."
helm upgrade --install argocd argo/argo-cd \
  -n argocd --create-namespace \
  --set server.service.type=NodePort \
  --set server.service.nodePortHttp=30090 \
  --set configs.params."server\.insecure"=true \
  --wait

echo "==> Creating demo namespace..."
kubectl create namespace demo --dry-run=client -o yaml | kubectl apply -f -

SEALED_DIR="${SCRIPT_DIR}/../sealed-secrets"
if ! ls "${SEALED_DIR}"/*.yaml &>/dev/null 2>&1; then
  echo "==> No sealed secret files found. Generating now..."
  bash "${SEALED_DIR}/seal-secrets.sh"
fi
echo "==> Applying sealed secrets..."
kubectl apply -f "${SEALED_DIR}/"

echo "==> Applying ArgoCD ApplicationSet..."
kubectl apply -f "${SCRIPT_DIR}/../argocd/applicationset.yaml"

ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "(not yet available)")

echo ""
echo "=== Bootstrap complete ==="
echo "  Cluster:          ${CLUSTER_NAME}"
echo "  CNPG operator:    cnpg-system"
echo "  Sealed Secrets:   kube-system"
echo "  ArgoCD:           argocd"
echo "  App namespace:    demo"
echo ""
echo "  NodePort 30080 -> localhost:8082  (app HTTP)"
echo "  NodePort 30443 -> localhost:9443  (app HTTPS)"
echo "  NodePort 30090 -> localhost:9090  (ArgoCD UI)"
echo ""
echo "  ArgoCD admin password: ${ARGOCD_PASSWORD}"
echo "  Login: argocd login localhost:9090 --username admin --password \${ARGOCD_PASSWORD} --insecure"
echo ""
echo "  ApplicationSet 'video-demo' deployed. Watch: argocd app list"

# echo ""
# echo "==> Running E2E validation..."
# bash "${SCRIPT_DIR}/validate.sh"
