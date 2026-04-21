#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# setup.sh — KUBE972 Workshop — Kind cluster bootstrap
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

CLUSTER_NAME="k8s-workshop"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIND_CONFIG="${SCRIPT_DIR}/kind-config.yaml"

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERR ]${NC}  $*" >&2; }
die()     { error "$*"; exit 1; }
header()  { echo -e "\n${BOLD}━━━  $*  ━━━${NC}\n"; }

# ---------------------------------------------------------------------------
# Version helpers
# ---------------------------------------------------------------------------

# Returns 0 if version $1 >= $2 (dot-separated integers)
version_ge() {
  local a="$1" b="$2"
  printf '%s\n%s\n' "$b" "$a" | sort -V | head -n1 | grep -qF "$b"
}

parse_semver() {
  # Strips leading 'v' and any build metadata suffix (e.g. v3.17.2+gabcdef → 3.17.2)
  echo "$1" | sed 's/^v//' | cut -d'+' -f1
}

# ---------------------------------------------------------------------------
# WSL2 detection and guidance
# ---------------------------------------------------------------------------

is_wsl2() {
  [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi "microsoft" /proc/version 2>/dev/null
}

wsl2_guidance() {
  echo -e "${YELLOW}${BOLD}"
  echo "  ┌─────────────────────────────────────────────────────────┐"
  echo "  │                  WSL2 ENVIRONMENT DETECTED              │"
  echo "  └─────────────────────────────────────────────────────────┘"
  echo -e "${NC}"

  # Systemd check
  if ! systemctl is-system-running --quiet 2>/dev/null; then
    warn "systemd is NOT running. kind v0.31+ requires systemd in WSL2."
    echo -e "  Add this to ${BOLD}/etc/wsl.conf${NC} then run 'wsl --shutdown' from PowerShell:"
    echo -e "  ${BOLD}[boot]"
    echo -e "  systemd=true${NC}"
    echo ""
  else
    ok "systemd is running."
  fi

  # Memory check
  local mem_kb total_gb
  mem_kb=$(grep -m1 MemTotal /proc/meminfo | awk '{print $2}')
  total_gb=$(( mem_kb / 1024 / 1024 ))
  if [ "$total_gb" -lt 6 ]; then
    warn "Available RAM ≈ ${total_gb} GB — tight for the full stack (Nextcloud + PostgreSQL + monitoring)."
    echo -e "  Create/edit ${BOLD}%USERPROFILE%\\.wslconfig${NC} on Windows and add:"
    echo -e "  ${BOLD}[wsl2]"
    echo -e "  memory=6GB${NC}"
    echo ""
  else
    ok "Available RAM ≈ ${total_gb} GB."
  fi

  # Hosts file reminder
  info "Browser access to nextcloud.local / grafana.local from Windows requires editing:"
  echo -e "  ${BOLD}C:\\Windows\\System32\\drivers\\etc\\hosts${NC}  (needs Administrator)"
  echo -e "  Add:  ${BOLD}127.0.0.1  nextcloud.local grafana.local${NC}"
  echo ""

  # Filesystem reminder
  if [[ "${PWD}" == /mnt/* ]]; then
    warn "You are working under /mnt/... (Windows filesystem). This is slow."
    warn "Move your workspace to ~/projects/ inside WSL2 for better performance."
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------

check_prerequisites() {
  header "Checking prerequisites"
  local failed=0

  # docker
  if ! command -v docker &>/dev/null; then
    error "docker not found."
    error "  → Install Docker Desktop (Windows/macOS) or Docker Engine (Linux/WSL2)."
    failed=1
  elif ! docker info &>/dev/null 2>&1; then
    error "Docker daemon is not accessible. Is Docker running?"
    failed=1
  else
    ok "docker: $(docker --version)"
  fi

  # kind
  if ! command -v kind &>/dev/null; then
    error "kind not found."
    error "  → https://kind.sigs.k8s.io/docs/user/quick-start/#installation"
    failed=1
  else
    local kind_raw kind_ver
    kind_raw=$(kind version 2>/dev/null | awk '{print $2}')
    kind_ver=$(parse_semver "$kind_raw")
    if version_ge "$kind_ver" "0.31.0"; then
      ok "kind: ${kind_raw}"
    else
      error "kind ${kind_raw} is too old — v0.31+ required."
      error "  → https://github.com/kubernetes-sigs/kind/releases"
      failed=1
    fi
  fi

  # kubectl
  if ! command -v kubectl &>/dev/null; then
    error "kubectl not found."
    error "  → https://kubernetes.io/docs/tasks/tools/"
    failed=1
  else
    local kubectl_raw kubectl_ver kubectl_minor
    kubectl_raw=$(kubectl version --client -o json 2>/dev/null)
    kubectl_ver=$(echo "$kubectl_raw" | python3 -c \
      "import sys,json; v=json.load(sys.stdin)['clientVersion']; print(v['major']+'.'+v['minor'].rstrip('+'))" \
      2>/dev/null || kubectl version --client --short 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
    kubectl_minor=$(echo "$kubectl_ver" | cut -d. -f2)
    if [ "${kubectl_minor:-0}" -ge 35 ] 2>/dev/null; then
      ok "kubectl: v${kubectl_ver}"
    else
      warn "kubectl v${kubectl_ver} — v1.35+ recommended. Some features may differ."
      ok "kubectl: v${kubectl_ver} (accepted with warning)"
    fi
  fi

  # helm
  if ! command -v helm &>/dev/null; then
    error "helm not found."
    error "  → https://helm.sh/docs/intro/install/"
    failed=1
  else
    local helm_raw helm_ver
    helm_raw=$(helm version --short 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    helm_ver=$(parse_semver "$helm_raw")
    if version_ge "$helm_ver" "3.17.0"; then
      ok "helm: ${helm_raw}"
    else
      warn "helm ${helm_raw} — v3.17+ recommended."
      ok "helm: ${helm_raw} (accepted with warning)"
    fi
  fi

  if [ "$failed" -ne 0 ]; then
    echo ""
    die "One or more required tools are missing. Fix the errors above and re-run."
  fi
}

# ---------------------------------------------------------------------------
# Cluster lifecycle
# ---------------------------------------------------------------------------

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qxF "${CLUSTER_NAME}"
}

confirm_delete() {
  warn "Cluster '${CLUSTER_NAME}' already exists."
  printf "  Delete it and start fresh? [y/N] "
  read -r answer
  case "${answer,,}" in
    y|yes) ;;
    *)
      info "Keeping existing cluster. Run 'kubectl get nodes' to verify its state."
      exit 0
      ;;
  esac
  info "Deleting cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "${CLUSTER_NAME}"
  ok "Cluster deleted."
}

create_cluster() {
  header "Creating kind cluster"

  [ -f "${KIND_CONFIG}" ] || die "Config file not found: ${KIND_CONFIG}"

  info "Config: ${KIND_CONFIG}"
  info "This will pull kind node images (~800 MB on first run — be patient)."
  echo ""
  kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
  ok "Cluster '${CLUSTER_NAME}' created."
}

wait_nodes_ready() {
  header "Waiting for nodes"
  local timeout=180 elapsed=0 interval=5

  while true; do
    local total not_ready
    total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    not_ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -vc " Ready " || true)

    if [ "${total}" -ge 3 ] && [ "${not_ready}" -eq 0 ]; then
      ok "All ${total} nodes are Ready."
      echo ""
      kubectl get nodes -o wide
      break
    fi

    if [ "${elapsed}" -ge "${timeout}" ]; then
      error "Timed out after ${timeout}s waiting for nodes."
      kubectl get nodes
      die "Check 'docker ps' and 'kind get clusters' for details."
    fi

    printf "  Nodes ready: %d/%d — waiting... (%ds)\r" \
      "$(( total - not_ready ))" "${total}" "${elapsed}"
    sleep "${interval}"
    elapsed=$(( elapsed + interval ))
  done
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary() {
  header "Bootstrap complete"

  echo -e "${GREEN}${BOLD}Cluster '${CLUSTER_NAME}' is ready.${NC}"
  echo ""
  echo -e "${BOLD}Context set to:${NC} $(kubectl config current-context)"
  echo ""
  echo -e "${BOLD}Day 1 — next steps:${NC}"
  echo "  1. Open docs/DAY1.md and follow the instructions."
  echo "  2. Fill in manifests/00-namespaces/namespaces.yaml (create the 4 namespaces)."
  echo "  3. Install MetalLB — see manifests/01-metallb/README.md"
  echo "     Tip: run 'docker network inspect kind' to find the IP range for MetalLB."
  echo "  4. Install Traefik — see manifests/02-traefik/README.md"
  echo "  5. Validate: bash scripts/validate-day1.sh"
  echo ""

  if is_wsl2; then
    echo -e "${YELLOW}WSL2 reminder:${NC} To access nextcloud.local / grafana.local from your"
    echo "  Windows browser, add to C:\\Windows\\System32\\drivers\\etc\\hosts (as Administrator):"
    echo "    127.0.0.1  nextcloud.local grafana.local"
    echo ""
  fi

  echo -e "${BOLD}Quick reference:${NC}"
  echo "  kubectl get nodes"
  echo "  kubectl get pods -A"
  echo "  kind delete cluster --name ${CLUSTER_NAME}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  echo ""
  echo -e "${BOLD}${BLUE}  KUBE972 — Kubernetes Workshop — Cluster Bootstrap${NC}"
  echo -e "  kind cluster: ${BOLD}${CLUSTER_NAME}${NC}"
  echo ""

  if is_wsl2; then
    wsl2_guidance
  fi

  check_prerequisites

  if cluster_exists; then
    confirm_delete
  fi

  create_cluster
  wait_nodes_ready
  print_summary
}

main "$@"
