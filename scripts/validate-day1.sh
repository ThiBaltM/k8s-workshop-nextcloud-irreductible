#!/usr/bin/env bash
# =============================================================================
# validate-day1.sh — Day 1 validation: cluster + infrastructure layer
#
# Usage:
#   bash scripts/validate-day1.sh
#
# Checks:
#   - kind cluster is reachable and has 3 Ready nodes
#   - Required namespaces exist (nextcloud, monitoring, traefik, metallb-system)
#   - MetalLB pods are Running and an IPAddressPool is configured
#   - Traefik pod is Running and its Service has an EXTERNAL-IP
#   - A default StorageClass is available
#   - At least one test Ingress returns HTTP 200
#
# Exit code: 0 if all checks pass, 1 otherwise.
# Safe to run multiple times (read-only — makes no changes to the cluster).
# =============================================================================

set -uo pipefail

# ── Terminal colors (disabled if not a tty) ──────────────────────────────────
if [ -t 1 ]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
  BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; BOLD=''; DIM=''; NC=''
fi

# ── Counters ─────────────────────────────────────────────────────────────────
PASSED=0; FAILED=0; WARNINGS=0

# ── Output helpers ───────────────────────────────────────────────────────────
ok()   { echo -e "  ${GREEN}✓ PASS${NC}  $*"; }
fail() { echo -e "  ${RED}✗ FAIL${NC}  $*"; }
warn() { echo -e "  ${YELLOW}⚠ WARN${NC}  $*"; }
hint() { echo -e "        ${DIM}→ $*${NC}"; }
hdr()  { echo -e "\n${BOLD}$*${NC}"; }

# ── run_check <description> <function> [<hint-on-failure>] ───────────────────
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

# ── run_warning: non-blocking check ──────────────────────────────────────────
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

# ── Cluster nodes ─────────────────────────────────────────────────────────────
check_node_count() {
  local count
  count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "${count:-0}" -ge 3 ]
}

check_nodes_ready() {
  local total ready
  total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)
  [ "${total:-0}" -ge 3 ] && [ "$total" -eq "${ready:-0}" ]
}

# ── Namespaces ────────────────────────────────────────────────────────────────
check_ns_nextcloud()   { kubectl get namespace nextcloud    --no-headers 2>/dev/null | grep -q "Active"; }
check_ns_monitoring()  { kubectl get namespace monitoring   --no-headers 2>/dev/null | grep -q "Active"; }
check_ns_traefik()     { kubectl get namespace traefik      --no-headers 2>/dev/null | grep -q "Active"; }
check_ns_metallb()     { kubectl get namespace metallb-system --no-headers 2>/dev/null | grep -q "Active"; }

# ── MetalLB ───────────────────────────────────────────────────────────────────
check_metallb_pods() {
  local running
  running=$(kubectl get pods -n metallb-system --no-headers 2>/dev/null | grep -c "Running" || true)
  [ "${running:-0}" -ge 2 ]   # controller + at least 1 speaker
}

check_metallb_pool() {
  local count
  count=$(kubectl get ipaddresspool -n metallb-system --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "${count:-0}" -ge 1 ]
}

check_metallb_advertisement() {
  local count
  count=$(kubectl get l2advertisement -n metallb-system --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "${count:-0}" -ge 1 ]
}

# ── Traefik ───────────────────────────────────────────────────────────────────
check_traefik_pod() {
  kubectl get pods -n traefik --no-headers 2>/dev/null | grep -q "Running"
}

check_traefik_external_ip() {
  local ip
  ip=$(kubectl get svc -n traefik \
       -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  [ -n "${ip:-}" ] && [ "$ip" != "<pending>" ] && [ "$ip" != "null" ]
}

# ── StorageClass ──────────────────────────────────────────────────────────────
check_default_storageclass() {
  kubectl get storageclass --no-headers 2>/dev/null | grep -q "(default)"
}

# ── Test Ingress ──────────────────────────────────────────────────────────────
# Looks for any Ingress (across all non-system namespaces) and attempts
# to reach it via the Traefik external IP using a Host header.
# This does not assume a specific Ingress name or namespace.
check_test_ingress() {
  if ! command -v curl &>/dev/null; then
    return 1
  fi

  # Find the Traefik external IP
  local ip
  ip=$(kubectl get svc -n traefik \
       -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null)

  # Find the first non-system Ingress with a host defined
  local host
  host=$(kubectl get ingress -A \
         --field-selector='metadata.namespace!=kube-system,metadata.namespace!=metallb-system,metadata.namespace!=traefik,metadata.namespace!=cert-manager,metadata.namespace!=monitoring' \
         -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || true)

  [ -z "${host:-}" ] && return 1

  local status
  # Try via Traefik IP + Host header (works even if hosts file is not configured)
  if [ -n "${ip:-}" ]; then
    status=$(curl -s -o /dev/null -w "%{http_code}" \
             --max-time 8 --connect-timeout 4 \
             -H "Host: $host" "http://$ip" 2>/dev/null || echo "000")
    [ "$status" = "200" ] && return 0
  fi

  # Fallback: direct URL (requires hosts file to be configured)
  status=$(curl -s -o /dev/null -w "%{http_code}" \
           --max-time 8 --connect-timeout 4 \
           "http://$host" 2>/dev/null || echo "000")
  [ "$status" = "200" ]
}

check_test_ingress_exists() {
  local count
  count=$(kubectl get ingress -A \
          --field-selector='metadata.namespace!=kube-system' \
          --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "${count:-0}" -ge 1 ]
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  Day 1 Validation — Cluster + Infrastructure Layer${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  # ── Preflight ───────────────────────────────────────────────────────────────
  hdr "Preflight"
  if ! check_kubectl_reachable; then
    fail "kubectl cannot reach the cluster"
    hint "Is your kind cluster running? Try: kind get clusters && kubectl cluster-info"
    echo ""
    echo -e "  ${RED}${BOLD}Preflight failed — cannot continue without a reachable cluster.${NC}"
    exit 1
  fi
  ok "kubectl can reach the cluster"
  PASSED=$((PASSED + 1))

  # ── Cluster ─────────────────────────────────────────────────────────────────
  hdr "Cluster nodes"
  run_check "At least 3 nodes exist" check_node_count \
    "Expected 1 control-plane + 2 workers. Run: kind create cluster --config cluster/kind-config.yaml"
  run_check "All nodes are Ready" check_nodes_ready \
    "Some nodes are not Ready. Check: kubectl get nodes && kubectl describe node <name>"

  # ── Namespaces ───────────────────────────────────────────────────────────────
  hdr "Namespaces"
  run_check "Namespace 'nextcloud' exists"      check_ns_nextcloud \
    "Apply manifests/00-namespaces/namespaces.yaml"
  run_check "Namespace 'monitoring' exists"     check_ns_monitoring \
    "Apply manifests/00-namespaces/namespaces.yaml"
  run_check "Namespace 'traefik' exists"        check_ns_traefik \
    "Apply manifests/00-namespaces/namespaces.yaml"
  run_check "Namespace 'metallb-system' exists" check_ns_metallb \
    "Apply manifests/00-namespaces/namespaces.yaml"

  # ── MetalLB ──────────────────────────────────────────────────────────────────
  hdr "MetalLB"
  run_check "MetalLB pods are Running" check_metallb_pods \
    "Install MetalLB via Helm into metallb-system. Check: kubectl get pods -n metallb-system"
  run_check "IPAddressPool is configured" check_metallb_pool \
    "Create an IPAddressPool in metallb-system. Find the Docker subnet with: docker network inspect kind"
  run_check "L2Advertisement is configured" check_metallb_advertisement \
    "Create an L2Advertisement referencing your IPAddressPool in metallb-system"

  # ── Traefik ──────────────────────────────────────────────────────────────────
  hdr "Traefik"
  run_check "Traefik pod is Running" check_traefik_pod \
    "Install Traefik via Helm into the traefik namespace. Check: kubectl get pods -n traefik"
  run_check "Traefik Service has an EXTERNAL-IP" check_traefik_external_ip \
    "Traefik Service is still <pending>. MetalLB must have an IPAddressPool configured first. Check: kubectl get svc -n traefik"

  # ── Storage ───────────────────────────────────────────────────────────────────
  hdr "Storage"
  run_check "A default StorageClass exists" check_default_storageclass \
    "kind ships with local-path-provisioner as the default StorageClass. Check: kubectl get storageclass"

  # ── Test Ingress ──────────────────────────────────────────────────────────────
  hdr "Networking — test Ingress"
  run_warning "A test Ingress exists" check_test_ingress_exists \
    "Deploy a test nginx pod, Service, and Ingress to validate the full traffic chain."
  run_warning "Test Ingress returns HTTP 200" check_test_ingress \
    "Check: kubectl get ingress -A && kubectl describe ingress <name>. Does curl return 200 with the Host header set?"

  # ── Summary ───────────────────────────────────────────────────────────────────
  local total=$((PASSED + FAILED))
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  if [ "$FAILED" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}All $total checks passed.${NC}"
    [ "$WARNINGS" -gt 0 ] && \
      echo -e "  ${YELLOW}$WARNINGS optional check(s) did not pass — review warnings above.${NC}"
    echo ""
    echo -e "  ${BOLD}Day 1 complete. Proceed to docs/DAY2.md.${NC}"
  else
    echo -e "  ${RED}${BOLD}$FAILED / $total check(s) FAILED.${NC}  $PASSED passed."
    [ "$WARNINGS" -gt 0 ] && \
      echo -e "  ${YELLOW}$WARNINGS warning(s).${NC}"
    echo ""
    echo -e "  Fix the failing checks above before starting Day 2."
  fi
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  [ "$FAILED" -eq 0 ]
}

main "$@"
