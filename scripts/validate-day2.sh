#!/usr/bin/env bash
# =============================================================================
# validate-day2.sh — Day 2 validation: application stack
#
# Usage:
#   bash scripts/validate-day2.sh
#
# Checks:
#   - Day 1 prerequisites still hold (nodes Ready, namespaces exist)
#   - CloudNativePG operator is installed
#   - PostgreSQL cluster has at least 1 primary + 1 replica, both Running
#   - Redis pod is Running and responding to PING
#   - Nextcloud pod has 2/2 containers Ready (PHP-FPM + nginx sidecar)
#   - All PVCs in the nextcloud namespace are Bound
#   - Nextcloud is reachable via Ingress (HTTP 200 or 302)
#   - Nextcloud login page is accessible
#
# Exit code: 0 if all checks pass, 1 otherwise.
# Safe to run multiple times (read-only — makes no changes to the cluster).
# =============================================================================

set -uo pipefail

# ── Terminal colors ───────────────────────────────────────────────────────────
if [ -t 1 ]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
  BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; BOLD=''; DIM=''; NC=''
fi

PASSED=0; FAILED=0; WARNINGS=0

ok()   { echo -e "  ${GREEN}✓ PASS${NC}  $*"; }
fail() { echo -e "  ${RED}✗ FAIL${NC}  $*"; }
warn() { echo -e "  ${YELLOW}⚠ WARN${NC}  $*"; }
hint() { echo -e "        ${DIM}→ $*${NC}"; }
hdr()  { echo -e "\n${BOLD}$*${NC}"; }

run_check() {
  local desc="$1" fn="$2" msg="${3:-}"
  if "$fn" 2>/dev/null; then
    ok "$desc"
    PASSED=$((PASSED + 1))
  else
    fail "$desc"
    FAILED=$((FAILED + 1))
    [ -n "$msg" ] && hint "$msg"
  fi
}

run_warning() {
  local desc="$1" fn="$2" msg="${3:-}"
  if "$fn" 2>/dev/null; then
    ok "$desc"
    PASSED=$((PASSED + 1))
  else
    warn "$desc"
    WARNINGS=$((WARNINGS + 1))
    [ -n "$msg" ] && hint "$msg"
  fi
}

# =============================================================================
# CHECK FUNCTIONS
# =============================================================================

# ── Preflight ─────────────────────────────────────────────────────────────────
check_kubectl_reachable() {
  kubectl cluster-info 2>/dev/null | grep -q "running"
}

# ── Day 1 prerequisites ───────────────────────────────────────────────────────
check_nodes_ready() {
  local total ready
  total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)
  [ "${total:-0}" -ge 3 ] && [ "$total" -eq "${ready:-0}" ]
}

check_ns_nextcloud() {
  kubectl get namespace nextcloud --no-headers 2>/dev/null | grep -q "Active"
}

# ── CloudNativePG operator ────────────────────────────────────────────────────
check_cnpg_crd_exists() {
  kubectl get crd clusters.postgresql.cnpg.io --no-headers 2>/dev/null | grep -q "clusters.postgresql.cnpg.io"
}

check_cnpg_operator_running() {
  kubectl get pods -n cnpg-system --no-headers 2>/dev/null | grep -q "Running"
}

# ── PostgreSQL cluster ────────────────────────────────────────────────────────
check_cnpg_cluster_exists() {
  local count
  count=$(kubectl get cluster -n nextcloud --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "${count:-0}" -ge 1 ]
}

check_cnpg_cluster_healthy() {
  # CNPG Cluster phase transitions: Downloading → Creating → Initializing → Healthy
  kubectl get cluster -n nextcloud \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -qi "healthy"
}

check_cnpg_primary_running() {
  # CNPG stores the current primary name in status.currentPrimary
  local primary_name
  primary_name=$(kubectl get cluster -n nextcloud \
    -o jsonpath='{.items[0].status.currentPrimary}' 2>/dev/null)
  [ -z "${primary_name:-}" ] && return 1
  kubectl get pod "$primary_name" -n nextcloud --no-headers 2>/dev/null | grep -q "Running"
}

check_cnpg_replica_running() {
  # CNPG v1.20+ uses cnpg.io/instanceRole label (not the old role= label)
  local replicas
  replicas=$(kubectl get pods -n nextcloud -l "cnpg.io/instanceRole=replica" --no-headers 2>/dev/null \
             | grep -c "Running" || true)
  [ "${replicas:-0}" -ge 1 ]
}

# ── Redis ─────────────────────────────────────────────────────────────────────
check_redis_running() {
  local running
  running=$(kubectl get pods -n nextcloud -l app=redis --no-headers 2>/dev/null \
            | grep -c "Running" || true)
  [ "${running:-0}" -ge 1 ]
}

check_redis_responds() {
  # Run `redis-cli ping` inside the Redis container
  local pod
  pod=$(kubectl get pods -n nextcloud -l app=redis --no-headers 2>/dev/null \
        | grep "Running" | awk '{print $1}' | head -1)
  [ -z "${pod:-}" ] && return 1
  kubectl exec -n nextcloud "$pod" -- redis-cli ping 2>/dev/null | grep -qi "PONG"
}

# ── PVCs ──────────────────────────────────────────────────────────────────────
check_pvcs_exist() {
  local count
  count=$(kubectl get pvc -n nextcloud --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "${count:-0}" -ge 1 ]
}

check_pvcs_bound() {
  local total unbound
  total=$(kubectl get pvc -n nextcloud --no-headers 2>/dev/null | wc -l | tr -d ' ')
  unbound=$(kubectl get pvc -n nextcloud --no-headers 2>/dev/null \
            | grep -vc "Bound" || true)
  [ "${total:-0}" -ge 1 ] && [ "${unbound:-1}" -eq 0 ]
}

# ── Nextcloud pod ─────────────────────────────────────────────────────────────
check_nextcloud_pod_exists() {
  local count
  count=$(kubectl get pods -n nextcloud -l app=nextcloud --no-headers 2>/dev/null \
          | wc -l | tr -d ' ')
  [ "${count:-0}" -ge 1 ]
}

check_nextcloud_containers_ready() {
  # Pod must have 2/2 containers Ready (PHP-FPM + nginx sidecar)
  local ready
  ready=$(kubectl get pods -n nextcloud -l app=nextcloud --no-headers 2>/dev/null \
          | grep "2/2" | grep -c "Running" || true)
  [ "${ready:-0}" -ge 1 ]
}

# ── Nextcloud Service + Ingress ───────────────────────────────────────────────
check_nextcloud_service() {
  local count
  count=$(kubectl get svc -n nextcloud -l app=nextcloud --no-headers 2>/dev/null \
          | wc -l | tr -d ' ')
  [ "${count:-0}" -ge 1 ]
}

check_nextcloud_ingress() {
  local count
  count=$(kubectl get ingress -n nextcloud --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "${count:-0}" -ge 1 ]
}

check_nextcloud_endpoints_populated() {
  # The Service must have at least one Endpoint (pod is reachable)
  local ep_count
  ep_count=$(kubectl get endpoints -n nextcloud -l app=nextcloud \
             -o jsonpath='{.items[0].subsets[0].addresses}' 2>/dev/null \
             | grep -c "ip" || true)
  [ "${ep_count:-0}" -ge 1 ]
}

# ── Nextcloud HTTP reachability ───────────────────────────────────────────────
_nextcloud_http_status() {
  command -v curl &>/dev/null || return 1

  # Try via Traefik IP + Host header (does not require hosts file)
  local ip
  ip=$(kubectl get svc -n traefik \
       -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

  # Determine the hostname from the Nextcloud Ingress
  local host
  host=$(kubectl get ingress -n nextcloud \
         -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || true)
  host="${host:-nextcloud.local}"

  local status="000"
  if [ -n "${ip:-}" ]; then
    status=$(curl -sk -o /dev/null -w "%{http_code}" \
             --max-time 10 --connect-timeout 5 \
             -H "Host: $host" "http://$ip" 2>/dev/null || echo "000")
    { [ "$status" = "200" ] || [ "$status" = "302" ] || [ "$status" = "301" ]; } && return 0
  fi

  # Fallback: direct URL (requires hosts file configuration)
  status=$(curl -sk -o /dev/null -w "%{http_code}" \
           --max-time 10 --connect-timeout 5 \
           "http://$host" 2>/dev/null || echo "000")
  [ "$status" = "200" ] || [ "$status" = "302" ] || [ "$status" = "301" ]
}

check_nextcloud_reachable() {
  _nextcloud_http_status
}

check_nextcloud_login_page() {
  command -v curl &>/dev/null || return 1

  local ip host body
  ip=$(kubectl get svc -n traefik \
       -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  host=$(kubectl get ingress -n nextcloud \
         -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || true)
  host="${host:-nextcloud.local}"

  if [ -n "${ip:-}" ]; then
    body=$(curl -skL -o - \
           --max-time 15 --connect-timeout 5 \
           -H "Host: $host" "http://$ip" 2>/dev/null || true)
    echo "$body" | grep -qi "nextcloud\|password\|login" && return 0
  fi

  body=$(curl -skL -o - \
         --max-time 15 --connect-timeout 5 \
         "http://$host" 2>/dev/null || true)
  echo "$body" | grep -qi "nextcloud\|password\|login"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  Day 2 Validation — Application Stack${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  # ── Preflight ────────────────────────────────────────────────────────────────
  hdr "Preflight"
  if ! check_kubectl_reachable; then
    fail "kubectl cannot reach the cluster"
    hint "Run: kind get clusters && kubectl cluster-info"
    exit 1
  fi
  ok "kubectl can reach the cluster"
  PASSED=$((PASSED + 1))

  # ── Day 1 sanity ─────────────────────────────────────────────────────────────
  hdr "Day 1 prerequisites"
  run_check "All cluster nodes are Ready" check_nodes_ready \
    "Day 1 must be complete before Day 2. Run: bash scripts/validate-day1.sh"
  run_check "Namespace 'nextcloud' exists" check_ns_nextcloud \
    "Apply manifests/00-namespaces/namespaces.yaml"

  # ── CloudNativePG operator ───────────────────────────────────────────────────
  hdr "CloudNativePG operator"
  run_check "CloudNativePG CRD is registered" check_cnpg_crd_exists \
    "Install the CNPG operator via Helm or kubectl apply. See manifests/04-postgresql/README.md"
  run_check "CloudNativePG operator pod is Running" check_cnpg_operator_running \
    "Check: kubectl get pods -n cnpg-system. The operator must be Running before applying a Cluster CRD."

  # ── PostgreSQL cluster ───────────────────────────────────────────────────────
  hdr "PostgreSQL cluster (CloudNativePG)"
  run_check "A Cluster resource exists in 'nextcloud'" check_cnpg_cluster_exists \
    "Apply manifests/04-postgresql/cluster.yaml. Check: kubectl get cluster -n nextcloud"
  run_check "Cluster phase is Healthy" check_cnpg_cluster_healthy \
    "Cluster is still initializing. Check: kubectl describe cluster <name> -n nextcloud (look at Status and Events)"
  run_check "Primary instance is Running" check_cnpg_primary_running \
    "Primary pod is not Running. Check: kubectl get pods -n nextcloud && kubectl logs <pod> -n nextcloud"
  run_check "Replica instance is Running" check_cnpg_replica_running \
    "No replica pod found. Your Cluster spec should have instances: 2. Check: kubectl get pods -n nextcloud -l cnpg.io/instanceRole=replica"

  # ── Redis ─────────────────────────────────────────────────────────────────────
  hdr "Redis"
  run_check "Redis pod is Running" check_redis_running \
    "Apply manifests/05-redis/redis.yaml. Check: kubectl get pods -n nextcloud -l app=redis"
  run_check "Redis responds to PING" check_redis_responds \
    "Redis pod is Running but not responding. Check: kubectl logs -n nextcloud <redis-pod>"

  # ── Persistent storage ────────────────────────────────────────────────────────
  hdr "Persistent storage"
  run_check "PVCs exist in 'nextcloud'" check_pvcs_exist \
    "Apply manifests/06-nextcloud/pvc.yaml. Check: kubectl get pvc -n nextcloud"
  run_check "All PVCs are Bound" check_pvcs_bound \
    "A PVC in Pending state usually means local-path-provisioner hasn't triggered yet — the pod must mount it first. Or the PVC spec has an unsupported accessMode."

  # ── Nextcloud pod ─────────────────────────────────────────────────────────────
  hdr "Nextcloud pod"
  run_check "Nextcloud pod exists" check_nextcloud_pod_exists \
    "Apply manifests/06-nextcloud/deployment.yaml. Check: kubectl get pods -n nextcloud -l app=nextcloud"
  run_check "Nextcloud pod has 2/2 containers Ready (FPM + nginx)" check_nextcloud_containers_ready \
    "Pod is Running but not 2/2. Check each container: kubectl logs <pod> -c nextcloud -n nextcloud && kubectl logs <pod> -c nginx -n nextcloud. Common causes: nginx 502 (FPM not reachable), FPM crash (DB connection refused)."

  # ── Service + Ingress ─────────────────────────────────────────────────────────
  hdr "Service and Ingress"
  run_check "Nextcloud Service exists" check_nextcloud_service \
    "Apply manifests/06-nextcloud/service.yaml. Check: kubectl get svc -n nextcloud"
  run_check "Nextcloud Ingress exists" check_nextcloud_ingress \
    "Apply manifests/07-ingress/ingress.yaml. Check: kubectl get ingress -n nextcloud"
  run_check "Nextcloud Service has endpoints (pod is reachable)" check_nextcloud_endpoints_populated \
    "Service exists but has no endpoints — the pod selector doesn't match the pod labels. Check: kubectl get endpoints -n nextcloud && kubectl describe svc nextcloud -n nextcloud"

  # ── HTTP reachability ─────────────────────────────────────────────────────────
  hdr "Nextcloud reachability"
  run_check "Nextcloud returns HTTP 200 or 302" check_nextcloud_reachable \
    "curl failed or returned an unexpected status. Check: kubectl describe ingress -n nextcloud. Is NEXTCLOUD_TRUSTED_DOMAINS set correctly in the ConfigMap?"
  run_warning "Nextcloud login page is accessible" check_nextcloud_login_page \
    "HTTP response does not contain a login page. Check: kubectl logs <nextcloud-pod> -c nginx -n nextcloud. Is Nextcloud done initializing? First boot can take 2–3 minutes."

  # ── Summary ───────────────────────────────────────────────────────────────────
  local total=$((PASSED + FAILED))
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  if [ "$FAILED" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}All $total checks passed.${NC}"
    [ "$WARNINGS" -gt 0 ] && \
      echo -e "  ${YELLOW}$WARNINGS optional check(s) did not pass — review warnings above.${NC}"
    echo ""
    echo -e "  ${BOLD}Day 2 complete. Proceed to docs/DAY3.md.${NC}"
  else
    echo -e "  ${RED}${BOLD}$FAILED / $total check(s) FAILED.${NC}  $PASSED passed."
    [ "$WARNINGS" -gt 0 ] && \
      echo -e "  ${YELLOW}$WARNINGS warning(s).${NC}"
    echo ""
    echo -e "  Fix the failing checks above before starting Day 3."
  fi
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  [ "$FAILED" -eq 0 ]
}

main "$@"
