#!/usr/bin/env bash
# =============================================================================
# validate-day3.sh — Day 3 validation: monitoring, TLS, and observability
#
# Usage:
#   bash scripts/validate-day3.sh
#
# Checks:
#   - Day 2 prerequisites still hold (Nextcloud pod ready, cluster healthy)
#   - cert-manager is installed and all pods are Running
#   - A ClusterIssuer exists and is in Ready state
#   - A Certificate resource exists in the nextcloud namespace (Ready)
#   - The Nextcloud Ingress has TLS configured
#   - Nextcloud is reachable over HTTPS
#   - kube-prometheus-stack is installed (Prometheus + Grafana + Alertmanager)
#   - Grafana Ingress exists
#   - Grafana is reachable over HTTPS
#   - At least one Certificate exists in the monitoring namespace (Grafana TLS)
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

# ── Day 2 prerequisites ───────────────────────────────────────────────────────
check_nextcloud_still_running() {
  local ready
  ready=$(kubectl get pods -n nextcloud -l app=nextcloud --no-headers 2>/dev/null \
          | grep "2/2" | grep -c "Running" || true)
  [ "${ready:-0}" -ge 1 ]
}

check_cnpg_still_healthy() {
  kubectl get cluster -n nextcloud \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -qi "healthy"
}

# ── cert-manager ──────────────────────────────────────────────────────────────
check_certmanager_crd() {
  kubectl get crd certificates.cert-manager.io --no-headers 2>/dev/null \
    | grep -q "certificates.cert-manager.io"
}

check_certmanager_pods() {
  # Expects cert-manager, cert-manager-cainjector, cert-manager-webhook
  local running
  running=$(kubectl get pods -n cert-manager --no-headers 2>/dev/null \
            | grep -c "Running" || true)
  [ "${running:-0}" -ge 3 ]
}

check_certmanager_webhook_ready() {
  local ready
  ready=$(kubectl get deployment -n cert-manager cert-manager-webhook \
          -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  [ "${ready:-0}" -ge 1 ]
}

# ── ClusterIssuer ─────────────────────────────────────────────────────────────
check_clusterissuer_exists() {
  local count
  count=$(kubectl get clusterissuer --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "${count:-0}" -ge 1 ]
}

check_clusterissuer_ready() {
  # Check that at least one ClusterIssuer has Ready=True condition
  local ready
  ready=$(kubectl get clusterissuer \
          -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' \
          2>/dev/null | grep -c "True" || true)
  [ "${ready:-0}" -ge 1 ]
}

# ── Nextcloud TLS ─────────────────────────────────────────────────────────────
check_nextcloud_cert_exists() {
  local count
  count=$(kubectl get certificate -n nextcloud --no-headers 2>/dev/null \
          | wc -l | tr -d ' ')
  [ "${count:-0}" -ge 1 ]
}

check_nextcloud_cert_ready() {
  local ready
  ready=$(kubectl get certificate -n nextcloud \
          -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' \
          2>/dev/null | grep -c "True" || true)
  [ "${ready:-0}" -ge 1 ]
}

check_nextcloud_ingress_tls() {
  # The Nextcloud Ingress must have a tls[] block with a secretName
  kubectl get ingress -n nextcloud \
    -o jsonpath='{.items[0].spec.tls[0].secretName}' 2>/dev/null \
    | grep -qv "^$\|null"
}

check_nextcloud_https() {
  command -v curl &>/dev/null || return 1

  local ip host status
  ip=$(kubectl get svc -n traefik \
       -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  host=$(kubectl get ingress -n nextcloud \
         -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || true)
  host="${host:-nextcloud.local}"

  if [ -n "${ip:-}" ]; then
    status=$(curl -sk -o /dev/null -w "%{http_code}" \
             --max-time 10 --connect-timeout 5 \
             -H "Host: $host" "https://$ip" 2>/dev/null || echo "000")
    { [ "$status" = "200" ] || [ "$status" = "302" ] || [ "$status" = "301" ]; } && return 0
  fi

  # Fallback: direct URL (requires hosts file)
  status=$(curl -sk -o /dev/null -w "%{http_code}" \
           --max-time 10 --connect-timeout 5 \
           "https://$host" 2>/dev/null || echo "000")
  [ "$status" = "200" ] || [ "$status" = "302" ] || [ "$status" = "301" ]
}

# ── kube-prometheus-stack ─────────────────────────────────────────────────────
check_prometheus_crd() {
  kubectl get crd prometheuses.monitoring.coreos.com --no-headers 2>/dev/null \
    | grep -q "prometheuses.monitoring.coreos.com"
}

check_prometheus_running() {
  local ready
  ready=$(kubectl get statefulset -n monitoring \
          -l app.kubernetes.io/name=prometheus \
          -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo "0")
  [ "${ready:-0}" -ge 1 ]
}

check_alertmanager_running() {
  local ready
  ready=$(kubectl get statefulset -n monitoring \
          -l app.kubernetes.io/name=alertmanager \
          -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo "0")
  [ "${ready:-0}" -ge 1 ]
}

check_grafana_running() {
  local ready
  ready=$(kubectl get deployment -n monitoring \
          -l app.kubernetes.io/name=grafana \
          -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  [ "${ready:-0}" -ge 1 ]
}

check_servicemonitors_exist() {
  # kube-prometheus-stack creates several ServiceMonitors by default
  local count
  count=$(kubectl get servicemonitor -n monitoring --no-headers 2>/dev/null \
          | wc -l | tr -d ' ')
  [ "${count:-0}" -ge 1 ]
}

# ── Grafana Ingress + TLS ─────────────────────────────────────────────────────
check_grafana_ingress_exists() {
  local count
  count=$(kubectl get ingress -n monitoring --no-headers 2>/dev/null \
          | wc -l | tr -d ' ')
  [ "${count:-0}" -ge 1 ]
}

check_grafana_cert_exists() {
  local count
  count=$(kubectl get certificate -n monitoring --no-headers 2>/dev/null \
          | wc -l | tr -d ' ')
  [ "${count:-0}" -ge 1 ]
}

check_grafana_cert_ready() {
  local ready
  ready=$(kubectl get certificate -n monitoring \
          -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' \
          2>/dev/null | grep -c "True" || true)
  [ "${ready:-0}" -ge 1 ]
}

check_grafana_ingress_tls() {
  kubectl get ingress -n monitoring \
    -o jsonpath='{.items[0].spec.tls[0].secretName}' 2>/dev/null \
    | grep -qv "^$\|null"
}

check_grafana_https() {
  command -v curl &>/dev/null || return 1

  local ip host status
  ip=$(kubectl get svc -n traefik \
       -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  host=$(kubectl get ingress -n monitoring \
         -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || true)
  host="${host:-grafana.local}"

  if [ -n "${ip:-}" ]; then
    status=$(curl -sk -o /dev/null -w "%{http_code}" \
             --max-time 10 --connect-timeout 5 \
             -H "Host: $host" "https://$ip" 2>/dev/null || echo "000")
    { [ "$status" = "200" ] || [ "$status" = "302" ]; } && return 0
  fi

  # Fallback: direct URL (requires hosts file)
  status=$(curl -sk -o /dev/null -w "%{http_code}" \
           --max-time 10 --connect-timeout 5 \
           "https://$host" 2>/dev/null || echo "000")
  [ "$status" = "200" ] || [ "$status" = "302" ]
}

# ── CloudNativePG metrics ─────────────────────────────────────────────────────
check_cnpg_podmonitor_exists() {
  local count
  count=$(kubectl get podmonitor -n nextcloud --no-headers 2>/dev/null \
          | wc -l | tr -d ' ')
  [ "${count:-0}" -ge 1 ]
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  Day 3 Validation — Observability + TLS${NC}"
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

  # ── Day 2 sanity ─────────────────────────────────────────────────────────────
  hdr "Day 2 prerequisites"
  run_check "Nextcloud pod still has 2/2 containers Ready" check_nextcloud_still_running \
    "Day 2 must be complete before Day 3. Run: bash scripts/validate-day2.sh"
  run_check "PostgreSQL cluster still Healthy" check_cnpg_still_healthy \
    "CNPG cluster is no longer healthy. Check: kubectl get cluster -n nextcloud"

  # ── cert-manager ─────────────────────────────────────────────────────────────
  hdr "cert-manager"
  run_check "cert-manager CRDs are installed" check_certmanager_crd \
    "Install cert-manager via Helm with --set crds.enabled=true. See manifests/07-ingress/cert-manager/README.md"
  run_check "cert-manager pods are Running (3 expected)" check_certmanager_pods \
    "Expected: cert-manager, cert-manager-cainjector, cert-manager-webhook. Check: kubectl get pods -n cert-manager"
  run_check "cert-manager webhook is Ready" check_certmanager_webhook_ready \
    "The webhook must be Ready before you create Issuer or Certificate resources. Wait and retry."

  # ── ClusterIssuer ─────────────────────────────────────────────────────────────
  hdr "ClusterIssuer"
  run_check "A ClusterIssuer exists" check_clusterissuer_exists \
    "Create a self-signed ClusterIssuer. See manifests/07-ingress/cert-manager/README.md"
  run_check "ClusterIssuer is in Ready=True state" check_clusterissuer_ready \
    "ClusterIssuer is not Ready. Check: kubectl describe clusterissuer <name>. Common cause: cert-manager webhook was not ready when it was created — delete and re-apply the ClusterIssuer."

  # ── Nextcloud TLS ─────────────────────────────────────────────────────────────
  hdr "Nextcloud TLS"
  run_check "Certificate resource exists in 'nextcloud'" check_nextcloud_cert_exists \
    "cert-manager creates a Certificate automatically when it sees the annotation on the Ingress. Check: kubectl get certificate -n nextcloud"
  run_check "Nextcloud Certificate is Ready=True" check_nextcloud_cert_ready \
    "Certificate is not Ready. Check: kubectl describe certificate <name> -n nextcloud. Common causes: wrong ClusterIssuer name in annotation, or Ingress was applied before ClusterIssuer was Ready."
  run_check "Nextcloud Ingress has TLS configured" check_nextcloud_ingress_tls \
    "Add a tls[] block to your Nextcloud Ingress spec and the cert-manager annotation. See manifests/07-ingress/ingress.yaml.skeleton"
  run_check "Nextcloud is reachable over HTTPS" check_nextcloud_https \
    "HTTPS request failed. Is the certificate Ready? Did you update OVERWRITEPROTOCOL to 'https' in your ConfigMap and restart the pod?"

  # ── kube-prometheus-stack ─────────────────────────────────────────────────────
  hdr "kube-prometheus-stack"
  run_check "Prometheus Operator CRDs are installed" check_prometheus_crd \
    "Install kube-prometheus-stack via Helm with --set crds.enabled=true. See manifests/08-monitoring/values.yaml.skeleton"
  run_check "Prometheus StatefulSet has Ready replicas" check_prometheus_running \
    "Prometheus is not ready. Check: kubectl get statefulset -n monitoring && kubectl describe pod -n monitoring -l app.kubernetes.io/name=prometheus"
  run_check "Alertmanager StatefulSet has Ready replicas" check_alertmanager_running \
    "Alertmanager is not ready. Check: kubectl get statefulset -n monitoring"
  run_check "Grafana Deployment has Ready replicas" check_grafana_running \
    "Grafana is not ready. Check: kubectl get deployment -n monitoring -l app.kubernetes.io/name=grafana"
  run_check "ServiceMonitors exist in 'monitoring'" check_servicemonitors_exist \
    "kube-prometheus-stack creates ServiceMonitors automatically. If none exist, the chart may not have installed correctly."

  # ── Grafana Ingress + TLS ─────────────────────────────────────────────────────
  hdr "Grafana Ingress and TLS"
  run_check "Grafana Ingress exists in 'monitoring'" check_grafana_ingress_exists \
    "Enable Grafana Ingress in values.yaml (grafana.ingress.enabled: true) and run helm upgrade."
  run_check "Grafana Certificate exists in 'monitoring'" check_grafana_cert_exists \
    "Add the cert-manager annotation and a tls[] block to the Grafana Ingress."
  run_check "Grafana Certificate is Ready=True" check_grafana_cert_ready \
    "Certificate not Ready. Check: kubectl describe certificate -n monitoring"
  run_check "Grafana Ingress has TLS configured" check_grafana_ingress_tls \
    "Add a tls[] block to the Grafana Ingress spec."
  run_check "Grafana is reachable over HTTPS" check_grafana_https \
    "HTTPS request to Grafana failed. Check Ingress host, TLS cert status, and Grafana pod logs."

  # ── CloudNativePG observability ───────────────────────────────────────────────
  hdr "CloudNativePG metrics"
  run_warning "A PodMonitor exists in 'nextcloud'" check_cnpg_podmonitor_exists \
    "Create a PodMonitor targeting the CloudNativePG pods. See DAY3.md Step 7. Without it, Prometheus cannot scrape PostgreSQL metrics."

  # ── Summary ───────────────────────────────────────────────────────────────────
  local total=$((PASSED + FAILED))
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  if [ "$FAILED" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}All $total checks passed.${NC}"
    [ "$WARNINGS" -gt 0 ] && \
      echo -e "  ${YELLOW}$WARNINGS optional check(s) did not pass — review warnings above.${NC}"
    echo ""
    echo -e "  ${BOLD}Day 3 technical work complete.${NC}"
    echo -e "  ${BOLD}Prepare your restitution — see docs/DAY3.md for the presentation format.${NC}"
  else
    echo -e "  ${RED}${BOLD}$FAILED / $total check(s) FAILED.${NC}  $PASSED passed."
    [ "$WARNINGS" -gt 0 ] && \
      echo -e "  ${YELLOW}$WARNINGS warning(s).${NC}"
    echo ""
    echo -e "  Fix the failing checks before the restitution."
  fi
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  [ "$FAILED" -eq 0 ]
}

main "$@"
