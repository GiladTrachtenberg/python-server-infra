# Video Demo Infrastructure

Kubernetes infrastructure for the
[video processing demo](https://github.com/giladtrachtenberg/python-server-adge):
shared Helm chart, Kind cluster setup, ArgoCD ApplicationSet, and sealed
secrets.

## Repository Layout

```
deploy/
├── app/                        # Shared Helm chart
│   ├── Chart.yaml
│   ├── values.yaml             # Default values
│   └── templates/
│       ├── deployment.yaml     # Pods, init containers, probes
│       ├── service.yaml        # ClusterIP / NodePort
│       ├── configmap.yaml      # Non-secret env vars
│       ├── migration-job.yaml  # Aerich DB migration (PreSync hook)
│       └── sealedsecret.yaml   # Bitnami SealedSecret
├── argocd/
│   └── applicationset.yaml     # Single ApplicationSet (6 apps)
├── infra/
│   └── cnpg-cluster/
│       └── cnpg-cluster.yaml   # PostgreSQL cluster (CNPG operator)
├── kind/
│   ├── kind-config.yaml        # 3-node cluster + port mappings
│   ├── bootstrap.sh            # Full cluster setup
│   ├── validate.sh             # E2E validation script
│   └── teardown.sh             # Cluster cleanup
└── sealed-secrets/
    └── seal-secrets.sh         # Generate cluster-bound encrypted secrets
```

## How It Works

### Two-Repo Split

| Concern       | This repo (infra)                        | App repo                                  |
|---------------|------------------------------------------|-------------------------------------------|
| Helm chart    | `deploy/app/` (templates + defaults)     | -                                         |
| Helm values   | -                                        | `deploy/app/values-*.yaml`, `deploy/web/` |
| Image tags    | -                                        | Updated by CI on each push                |
| Operators     | CNPG, SealedSecrets, ArgoCD              | -                                         |
| Kind config   | `deploy/kind/`                           | -                                         |

ArgoCD multi-source pulls the chart from this repo (HEAD) and values from the
app repo (HEAD). A CI push to the app repo updates an image tag in a values
file, ArgoCD detects it, and syncs.

### ApplicationSet

A single `ApplicationSet` generates 6 ArgoCD Applications with RollingSync
(progressive waves):

| Wave | App              | Source                             |
|------|------------------|------------------------------------|
| 1    | cnpg-cluster     | Git path (raw CNPG manifest)       |
| 2    | redis            | Bitnami Helm chart (v23)           |
| 3    | minio            | MinIO Helm chart (v5.4)            |
| 4    | video-demo-api   | Multi-source (chart + app values)  |
| 5    | video-demo-worker| Multi-source (chart + app values)  |
| 6    | video-demo-web   | Multi-source (chart + app values)  |

Infrastructure deploys first (waves 1-3), then application components (4-6).

### Shared Helm Chart

One chart (`deploy/app/`) serves API, Worker, and Web by toggling values:

- **API**: 2 replicas, health probes, migration job (PreSync), configMap, sharedSecrets
- **Worker**: 2 replicas, command override (`celery -A src.tasks worker`), no service, no migrations
- **Web**: 1 replica, nginx on port 80, NodePort 30080, init container waits for API

### Sealed Secrets

`seal-secrets.sh` generates random credentials and encrypts them with the
cluster's SealedSecrets controller key:

| Secret             | Contents                                                    |
|--------------------|-------------------------------------------------------------|
| cnpg-app-creds     | Postgres username + password (used by CNPG bootstrap)       |
| redis-password     | Redis auth password                                         |
| minio-creds        | MinIO root user + password                                  |
| app-shared-secrets | DATABASE_URL, REDIS_URL, CELERY_BROKER_URL, MinIO, JWT key  |

Secrets are cluster-bound: regenerate after recreating the Kind cluster.

## Quick Start

### Prerequisites

- Docker Desktop (running)
- `kind`, `helm`, `kubectl`, `kubeseal`, `jq` (bootstrap.sh will offer to install via Homebrew)

### Bootstrap

```bash
bash deploy/kind/bootstrap.sh
```

Creates a 3-node Kind cluster and installs:
- CNPG operator (PostgreSQL)
- Sealed Secrets controller
- ArgoCD (NodePort 30090)
- Generates and applies sealed secrets
- Deploys the ApplicationSet

### Access

After bootstrap finishes, wait about 60 seconds for ArgoCD to sync all apps.
Watch progress with:

```bash
kubectl get pods -n demo -w
```

Once all pods show `Running` / `Ready`:

| Service       | URL                     |
|---------------|-------------------------|
| App (web)     | http://localhost:8082    |
| ArgoCD UI     | http://localhost:9090    |
| ArgoCD login  | `admin` / (printed by bootstrap) |

Open http://localhost:8082, sign up, log in, and create a job. The status
updates from `pending` to `processing` to `completed` in real time via SSE.
Click into a completed job to download the generated file.

### Validate

```bash
bash deploy/kind/validate.sh
```

Runs 33 checks: prerequisites, ArgoCD sync status, pod health, endpoint health,
and a full user flow (register, login, create job, SSE stream, download,
token refresh).

### Teardown

```bash
bash deploy/kind/teardown.sh
```

Deletes the Kind cluster and cleans generated sealed secret files.

## Kind Cluster

3 nodes (1 control plane + 2 workers) with port mappings:

| Container Port | Host Port | Purpose     |
|----------------|-----------|-------------|
| 30080          | 8082      | App HTTP    |
| 30443          | 9443      | App HTTPS   |
| 30090          | 9090      | ArgoCD UI   |
