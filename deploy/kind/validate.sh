#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8082}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"
APP_NS="${APP_NS:-demo}"
TIMEOUT="${TIMEOUT:-120}"
WAIT_SYNC="${WAIT_SYNC:-true}"
SYNC_TIMEOUT="${SYNC_TIMEOUT:-60}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { ((++PASS)); echo -e "  ${GREEN}PASS${NC} $1"; }
fail() { ((++FAIL)); echo -e "  ${RED}FAIL${NC} $1"; }
warn() { ((++WARN)); echo -e "  ${YELLOW}WARN${NC} $1"; }
header() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

check_prereqs() {
    header "Prerequisites"

    if ! command -v kubectl &>/dev/null; then
        fail "kubectl not found"
        exit 1
    fi
    pass "kubectl available"

    if ! command -v curl &>/dev/null; then
        fail "curl not found"
        exit 1
    fi
    pass "curl available"

    if ! command -v jq &>/dev/null; then
        fail "jq not found (required for JSON parsing)"
        exit 1
    fi
    pass "jq available"

    local ctx
    ctx=$(kubectl config current-context 2>/dev/null || true)
    if [[ "$ctx" != "kind-video-demo" ]]; then
        fail "kubectl context is '$ctx', expected 'kind-video-demo'"
        exit 1
    fi
    pass "kubectl context: kind-video-demo"

    if ! kubectl cluster-info &>/dev/null; then
        fail "cluster not reachable"
        exit 1
    fi
    pass "cluster reachable"
}

wait_for_sync() {
    header "Waiting for ArgoCD Apps to Sync (timeout ${SYNC_TIMEOUT}s)"

    local expected_apps=("cnpg-cluster" "redis" "minio" "video-demo-api" "video-demo-worker" "video-demo-web")
    local deadline=$((SECONDS + SYNC_TIMEOUT))

    while [[ $SECONDS -lt $deadline ]]; do
        local all_synced=true
        local apps
        apps=$(kubectl get applications -n "$ARGOCD_NS" -o json 2>/dev/null || echo '{"items":[]}')
        local found_count
        found_count=$(echo "$apps" | jq '.items | length')

        if [[ "$found_count" -lt "${#expected_apps[@]}" ]]; then
            all_synced=false
        else
            for app_name in "${expected_apps[@]}"; do
                local sync health
                sync=$(echo "$apps" | jq -r ".items[] | select(.metadata.name==\"$app_name\") | .status.sync.status // \"\"")
                health=$(echo "$apps" | jq -r ".items[] | select(.metadata.name==\"$app_name\") | .status.health.status // \"\"")
                if [[ "$sync" != "Synced" || "$health" != "Healthy" ]]; then
                    all_synced=false
                    break
                fi
            done
        fi

        if [[ "$all_synced" == "true" ]]; then
            pass "all ${#expected_apps[@]} apps synced and healthy"
            return
        fi

        local remaining=$((deadline - SECONDS))
        echo -e "  ${YELLOW}...${found_count}/${#expected_apps[@]} apps found, waiting (${remaining}s left)${NC}"
        sleep 10
    done

    warn "sync timeout — proceeding with validation anyway"
}

check_argocd_apps() {
    header "ArgoCD Application Sync Status"

    local apps
    apps=$(kubectl get applications -n "$ARGOCD_NS" -o json 2>/dev/null)
    local count
    count=$(echo "$apps" | jq '.items | length')

    if [[ "$count" -eq 0 ]]; then
        fail "no ArgoCD Applications found in $ARGOCD_NS"
        return
    fi

    local expected_apps=("cnpg-cluster" "redis" "minio" "video-demo-api" "video-demo-worker" "video-demo-web")

    for app_name in "${expected_apps[@]}"; do
        local sync_status health_status
        sync_status=$(echo "$apps" | jq -r ".items[] | select(.metadata.name==\"$app_name\") | .status.sync.status // \"NotFound\"")
        health_status=$(echo "$apps" | jq -r ".items[] | select(.metadata.name==\"$app_name\") | .status.health.status // \"NotFound\"")

        if [[ "$sync_status" == "NotFound" || -z "$sync_status" ]]; then
            fail "$app_name: not found"
        elif [[ "$sync_status" == "Synced" && "$health_status" == "Healthy" ]]; then
            pass "$app_name: Synced / Healthy"
        elif [[ "$sync_status" == "Synced" ]]; then
            warn "$app_name: Synced / $health_status"
        else
            fail "$app_name: $sync_status / $health_status"
        fi
    done
}

check_pods() {
    header "Pod Status ($APP_NS namespace)"

    local pods
    pods=$(kubectl get pods -n "$APP_NS" -o json 2>/dev/null)
    local pod_count
    pod_count=$(echo "$pods" | jq '.items | length')

    if [[ "$pod_count" -eq 0 ]]; then
        fail "no pods found in $APP_NS namespace"
        return
    fi

    while read -r name phase ready; do
        if [[ "$phase" == "Succeeded" ]]; then
            pass "$name: $phase (completed job)"
        elif [[ "$phase" == "Running" && "$ready" == "true" ]]; then
            pass "$name: Running / Ready"
        elif [[ "$phase" == "Running" ]]; then
            warn "$name: Running / Not Ready"
        else
            fail "$name: $phase"
        fi
    done < <(echo "$pods" | jq -r '.items[] | "\(.metadata.name) \(.status.phase) \(.status.containerStatuses[0].ready // false)"')
}

check_services() {
    header "Services ($APP_NS namespace)"

    local expected=("video-demo-api" "video-demo-web")
    for svc in "${expected[@]}"; do
        if kubectl get svc "$svc" -n "$APP_NS" &>/dev/null; then
            pass "service $svc exists"
        else
            fail "service $svc not found"
        fi
    done
}

check_endpoint_health() {
    header "Endpoint Health (via $BASE_URL)"

    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$BASE_URL/" 2>/dev/null || echo "000")
    if [[ "$status" == "200" ]]; then
        pass "GET / (frontend): $status"
    else
        fail "GET / (frontend): $status"
    fi

    local healthz_body
    healthz_body=$(kubectl exec -n "$APP_NS" deploy/video-demo-api -- python -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8000/healthz').read().decode())" 2>/dev/null || echo "")
    if [[ "$healthz_body" == *'"ok"'* ]]; then
        pass "GET /healthz (in-cluster): ok"
    else
        fail "GET /healthz (in-cluster): $healthz_body"
    fi

    local readyz_body
    readyz_body=$(kubectl exec -n "$APP_NS" deploy/video-demo-api -- python -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8000/readyz').read().decode())" 2>/dev/null || echo "")
    if [[ "$readyz_body" == *'"ok"'* ]]; then
        pass "GET /readyz (in-cluster): ok"
    else
        fail "GET /readyz (in-cluster): $readyz_body"
    fi
}

run_full_flow() {
    header "Full User Flow"

    local ts
    ts=$(date +%s)
    local email="validate-${ts}@example.com"
    local password="Val1dP@ss${ts}"

    echo -e "  ${CYAN}Registering $email...${NC}"
    local register_resp
    register_resp=$(curl -s --max-time 10 \
        -X POST "$BASE_URL/api/v1/auth/register" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$email\",\"password\":\"$password\"}" 2>/dev/null)
    local register_status
    register_status=$(echo "$register_resp" | jq -r '.data.email // .email // empty')
    if [[ -n "$register_status" ]]; then
        pass "register: created $register_status"
    else
        fail "register: $register_resp"
        return
    fi

    echo -e "  ${CYAN}Logging in...${NC}"
    local login_resp
    login_resp=$(curl -s --max-time 10 \
        -X POST "$BASE_URL/api/v1/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$email\",\"password\":\"$password\"}" 2>/dev/null)
    local access_token refresh_token
    access_token=$(echo "$login_resp" | jq -r '.data.access_token // .access_token // empty')
    refresh_token=$(echo "$login_resp" | jq -r '.data.refresh_token // .refresh_token // empty')
    if [[ -n "$access_token" && -n "$refresh_token" ]]; then
        pass "login: got access + refresh tokens"
    else
        fail "login: $login_resp"
        return
    fi

    echo -e "  ${CYAN}Creating job...${NC}"
    local job_resp
    job_resp=$(curl -s --max-time 10 \
        -X POST "$BASE_URL/api/v1/jobs" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $access_token" 2>/dev/null)
    local job_id job_status
    job_id=$(echo "$job_resp" | jq -r '.data.id // .id // empty')
    job_status=$(echo "$job_resp" | jq -r '.data.status // .status // empty')
    if [[ -n "$job_id" ]]; then
        pass "create job: id=$job_id status=$job_status"
    else
        fail "create job: $job_resp"
        return
    fi

    echo -e "  ${CYAN}Connecting to user-scoped SSE (timeout ${TIMEOUT}s)...${NC}"
    local sse_completed=false
    local sse_url="$BASE_URL/api/v1/jobs/events?token=$access_token"

    while IFS= read -r line; do
        if [[ "$line" == data:* ]]; then
            local data="${line#data:}"
            data="${data#"${data%%[![:space:]]*}"}"
            if [[ "$data" != *"$job_id"* ]]; then
                continue
            fi
            echo -e "    SSE event: $data"
            if [[ "$data" == *"completed"* || "$data" == *"COMPLETED"* ]]; then
                sse_completed=true
                break
            fi
            if [[ "$data" == *"failed"* || "$data" == *"FAILED"* ]]; then
                fail "SSE: job failed"
                return
            fi
        fi
    done < <(curl -sN --max-time "$TIMEOUT" "$sse_url" 2>/dev/null || true)

    if [[ "$sse_completed" == "true" ]]; then
        pass "SSE: received completed event"
    else
        fail "SSE: did not receive completed within ${TIMEOUT}s"
        return
    fi

    echo -e "  ${CYAN}Fetching job details...${NC}"
    local detail_resp
    detail_resp=$(curl -s --max-time 10 \
        -H "Authorization: Bearer $access_token" \
        "$BASE_URL/api/v1/jobs/$job_id" 2>/dev/null)
    local download_url final_status
    download_url=$(echo "$detail_resp" | jq -r '.data.download_url // .download_url // empty')
    final_status=$(echo "$detail_resp" | jq -r '.data.status // .status // empty')

    if [[ "$final_status" == "completed" || "$final_status" == "COMPLETED" ]]; then
        pass "job status: $final_status"
    else
        fail "job status: $final_status (expected completed)"
    fi

    if [[ -n "$download_url" ]]; then
        pass "presigned download URL present"
    else
        warn "no download_url in response (MinIO may not be externally reachable)"
        return
    fi

    echo -e "  ${CYAN}Testing download...${NC}"
    local dl_status
    dl_status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 "$download_url" 2>/dev/null || echo "000")
    if [[ "$dl_status" == "200" ]]; then
        pass "download: HTTP $dl_status"
    else
        warn "download: HTTP $dl_status (presigned URL may point to cluster-internal MinIO)"
    fi

    echo -e "  ${CYAN}Testing token refresh...${NC}"
    local refresh_resp
    refresh_resp=$(curl -s --max-time 10 \
        -X POST "$BASE_URL/api/v1/auth/refresh" \
        -H "Content-Type: application/json" \
        -d "{\"refresh_token\":\"$refresh_token\"}" 2>/dev/null)
    local new_access
    new_access=$(echo "$refresh_resp" | jq -r '.data.access_token // .access_token // empty')
    if [[ -n "$new_access" ]]; then
        pass "token refresh: got new access token"
    else
        fail "token refresh: $refresh_resp"
    fi
}

print_summary() {
    header "Summary"
    echo -e "  ${GREEN}Passed: $PASS${NC}"
    [[ "$WARN" -gt 0 ]] && echo -e "  ${YELLOW}Warnings: $WARN${NC}"
    [[ "$FAIL" -gt 0 ]] && echo -e "  ${RED}Failed: $FAIL${NC}"

    if [[ "$FAIL" -gt 0 ]]; then
        echo -e "\n${RED}VALIDATION FAILED${NC}"
        exit 1
    elif [[ "$WARN" -gt 0 ]]; then
        echo -e "\n${YELLOW}VALIDATION PASSED WITH WARNINGS${NC}"
    else
        echo -e "\n${GREEN}VALIDATION PASSED${NC}"
    fi
}

main() {
    echo -e "${CYAN}Kind E2E Validation — video-demo${NC}"
    echo "Base URL:     $BASE_URL"
    echo "SSE Timeout:  ${TIMEOUT}s"
    echo "Wait Sync:    $WAIT_SYNC (SYNC_TIMEOUT=${SYNC_TIMEOUT}s)"

    check_prereqs
    [[ "$WAIT_SYNC" == "true" ]] && wait_for_sync
    check_argocd_apps
    check_pods
    check_services
    check_endpoint_health
    run_full_flow
    print_summary
}

main "$@"
