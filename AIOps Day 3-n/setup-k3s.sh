#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────
# Usage
# ─────────────────────────────────────────────
# ./setup-k3s.sh            — interactive mode (approve/skip each step)
# ./setup-k3s.sh --yes      — non-interactive: run all steps automatically
# ./setup-k3s.sh --skip 2,5 — skip specific steps, run the rest

usage() {
  echo "Usage: $0 [--yes] [--skip <step,step,...>]"
  echo "  --yes            Run all steps without prompting"
  echo "  --skip 2,5,6     Skip specific step numbers (comma-separated)"
  exit 1
}

AUTO_YES=false
SKIP_STEPS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)  AUTO_YES=true; shift ;;
    --skip) IFS=',' read -ra SKIP_STEPS <<< "$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$*"; exit 1; }

# is_skipped <step_number>
is_skipped() {
  local n=$1
  for s in "${SKIP_STEPS[@]:-}"; do
    [[ "$s" == "$n" ]] && return 0
  done
  return 1
}

# approve <step_number> <title> <description>
# Returns 0 to proceed, 1 to skip.
approve() {
  local step=$1 title=$2 desc=$3

  if is_skipped "$step"; then
    warn "Step $step ($title) — SKIPPED via --skip flag."
    return 1
  fi

  if $AUTO_YES; then
    info "Step $step ($title) — auto-approved (--yes)."
    return 0
  fi

  echo ""
  echo -e "${CYAN}${BOLD}┌─────────────────────────────────────────────────────┐${NC}"
  echo -e "${CYAN}${BOLD}│ STEP $step: $title${NC}"
  echo -e "${CYAN}  $desc${NC}"
  echo -e "${CYAN}${BOLD}└─────────────────────────────────────────────────────┘${NC}"
  while true; do
    echo -en "  Proceed? [${BOLD}y${NC}]es / [${BOLD}s${NC}]kip / [${BOLD}q${NC}]uit : "
    read -r REPLY </dev/tty
    case "${REPLY,,}" in
      y|yes|"") return 0 ;;
      s|skip)
        warn "Step $step ($title) — skipped by user."
        return 1 ;;
      q|quit)
        warn "Aborted by user at Step $step."
        exit 0 ;;
      *) echo "  Please enter y, s, or q." ;;
    esac
  done
}

# Wait for a condition with timeout
# Usage: wait_for <timeout_seconds> <interval_seconds> <description> <command...>
wait_for() {
  local timeout=$1 interval=$2 desc=$3
  shift 3
  local elapsed=0
  info "Waiting for: $desc (timeout: ${timeout}s)"
  while ! "$@" &>/dev/null; do
    if (( elapsed >= timeout )); then
      die "Timed out waiting for: $desc"
    fi
    echo -n "."
    sleep "$interval"
    (( elapsed += interval ))
  done
  echo ""
  info "Ready: $desc"
}

# Wait for a kubectl resource to reach a ready state
wait_for_rollout() {
  local kind=$1 name=$2 namespace=$3 timeout=${4:-180}
  info "Waiting for $kind/$name in namespace '$namespace' to be available..."
  kubectl rollout status "$kind/$name" -n "$namespace" --timeout="${timeout}s" \
    || die "$kind/$name did not become ready within ${timeout}s"
  info "$kind/$name is ready."
}

# ─────────────────────────────────────────────
# Step 1 — Detect non-localhost IP
# ─────────────────────────────────────────────
info "=== Step 1: Detecting node IP ==="
NODE_IP=$(hostname -I | tr ' ' '\n' | grep -v '^127\.' | head -1)
[[ -z "$NODE_IP" ]] && die "Could not determine a non-localhost IP address."
info "Using IP address: $NODE_IP"

# ─────────────────────────────────────────────
# Step 2 — Install k3s
# ─────────────────────────────────────────────
if approve 2 "Install k3s" "Install k3s v1.23.9+k3s1 with node-ip=$NODE_IP. Skipped automatically if already running."; then
  if systemctl is-active --quiet k3s; then
    warn "k3s is already running — skipping installation."
  else
    info "k3s not found or not running. Installing..."
    sudo curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.23.9+k3s1" \
      K3S_TOKEN=skillpedia#1 sh -s - server \
      --node-ip="$NODE_IP" \
      --advertise-address="$NODE_IP" \
      --cluster-init
    wait_for 60 3 "k3s systemd service" systemctl is-active --quiet k3s
  fi
fi

# ─────────────────────────────────────────────
# Step 3 — Set up kubeconfig
# ─────────────────────────────────────────────
if approve 3 "Configure kubeconfig" "Copy /etc/rancher/k3s/k3s.yaml to ~/.kube/config and fix ownership."; then
  mkdir -p ~/.kube
  wait_for 30 2 "k3s kubeconfig at /etc/rancher/k3s/k3s.yaml" \
    test -f /etc/rancher/k3s/k3s.yaml

  if [[ -f ~/.kube/config ]]; then
    warn "~/.kube/config already exists — skipping copy."
  else
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown opc:opc ~/.kube/config
    info "kubeconfig copied."
  fi

  sudo chown opc:opc /etc/rancher/k3s/k3s.yaml
  info "kubeconfig configured."
fi

export KUBECONFIG=~/.kube/config

# ─────────────────────────────────────────────
# Step 4 — Verify cluster connectivity
# ─────────────────────────────────────────────
if approve 4 "Verify cluster connectivity" "Check that the Kubernetes API server is reachable and the node is Ready."; then
  wait_for 90 5 "Kubernetes API server" kubectl cluster-info
  info "Cluster is reachable."
  info "Waiting for node to become Ready..."
  wait_for 120 5 "node Ready" \
    bash -c "kubectl get nodes | grep -E '\bReady\b' | grep -v 'NotReady'"
fi

# ─────────────────────────────────────────────
# Step 5 — Patch metrics-server
# ─────────────────────────────────────────────
if approve 5 "Patch metrics-server" "Add --kubelet-insecure-tls and hostNetwork:true to the metrics-server deployment."; then

  # Clean up stuck Pending pods from a previous failed patch
  STUCK_PODS=$(kubectl get pods -n kube-system \
    --field-selector=status.phase=Pending \
    -o jsonpath='{.items[*].metadata.name}' \
    | tr ' ' '\n' | grep '^metrics-server' || true)

  if [[ -n "$STUCK_PODS" ]]; then
    warn "Found stuck Pending metrics-server pod(s): $STUCK_PODS — deleting."
    echo "$STUCK_PODS" | xargs kubectl delete pod -n kube-system --ignore-not-found
    info "Stuck pod(s) deleted."
  fi

  wait_for_rollout deployment metrics-server kube-system 180

  if kubectl get deployment metrics-server -n kube-system \
       -o jsonpath='{.spec.template.spec.containers[0].args}' \
     | grep -q 'kubelet-insecure-tls'; then
    warn "metrics-server already has --kubelet-insecure-tls — skipping patch."
  else
    kubectl patch deployment metrics-server \
      -n kube-system \
      --type='json' \
      -p='[
        {
          "op": "add",
          "path": "/spec/template/spec/containers/0/args/-",
          "value": "--kubelet-insecure-tls"
        },
        {
          "op": "add",
          "path": "/spec/template/spec/hostNetwork",
          "value": true
        }
      ]'
    wait_for_rollout deployment metrics-server kube-system 120
    info "metrics-server patched successfully."
  fi
fi

# ─────────────────────────────────────────────
# Step 6 — Deploy Kubernetes Dashboard
# ─────────────────────────────────────────────
if approve 6 "Deploy Kubernetes Dashboard" "Apply the official Dashboard v2.7.0 manifest from GitHub."; then
  if kubectl get deployment kubernetes-dashboard -n kubernetes-dashboard &>/dev/null; then
    warn "Kubernetes Dashboard already deployed — skipping apply."
  else
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml
    wait_for 30 3 "kubernetes-dashboard namespace" \
      bash -c "kubectl get namespace kubernetes-dashboard &>/dev/null"
  fi
  wait_for_rollout deployment kubernetes-dashboard kubernetes-dashboard 180
fi

# ─────────────────────────────────────────────
# Step 7 — Create admin-user
# ─────────────────────────────────────────────
if approve 7 "Create admin-user" "Create ServiceAccount and ClusterRoleBinding for dashboard admin access."; then

  cat > admin-user.yaml <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
EOF

  cat > admin-user-role.yaml <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF

  if kubectl get serviceaccount admin-user -n kubernetes-dashboard &>/dev/null \
     && kubectl get clusterrolebinding admin-user &>/dev/null; then
    warn "admin-user ServiceAccount and ClusterRoleBinding already exist — skipping apply."
  else
    kubectl apply -f admin-user.yaml
    kubectl apply -f admin-user-role.yaml
    info "admin-user ServiceAccount and ClusterRoleBinding applied."
  fi

  wait_for 30 3 "admin-user ServiceAccount" \
    bash -c "kubectl get serviceaccount admin-user -n kubernetes-dashboard &>/dev/null"
fi

# ─────────────────────────────────────────────
# Step 8 — Expose dashboard via NodePort
# ─────────────────────────────────────────────
if approve 8 "Expose Dashboard as NodePort" "Patch the kubernetes-dashboard service type to NodePort."; then
  wait_for 30 3 "kubernetes-dashboard service" \
    bash -c "kubectl get svc kubernetes-dashboard -n kubernetes-dashboard &>/dev/null"

  CURRENT_SVC_TYPE=$(kubectl get svc kubernetes-dashboard -n kubernetes-dashboard \
    -o jsonpath='{.spec.type}')

  if [[ "$CURRENT_SVC_TYPE" == "NodePort" ]]; then
    warn "kubernetes-dashboard service is already NodePort — skipping patch."
  else
    kubectl patch svc kubernetes-dashboard \
      -n kubernetes-dashboard \
      -p '{"spec": {"type": "NodePort"}}'
    wait_for 15 2 "NodePort assignment" \
      bash -c "kubectl get svc kubernetes-dashboard -n kubernetes-dashboard \
               -o jsonpath='{.spec.type}' | grep -q NodePort"
    info "Service patched to NodePort."
  fi

  info "Service details:"
  kubectl get svc kubernetes-dashboard -n kubernetes-dashboard
fi

# ─────────────────────────────────────────────
# Step 9 — Retrieve admin token
# ─────────────────────────────────────────────
if approve 9 "Retrieve admin token" "Fetch the bearer token for the admin-user ServiceAccount."; then
  wait_for 60 3 "admin-user-token Secret" \
    bash -c "kubectl get secret -n kubernetes-dashboard | grep -q 'admin-user-token'"

  TOKEN=$(kubectl -n kubernetes-dashboard describe secret \
    "$(kubectl -n kubernetes-dashboard get secret \
       | awk '/admin-user-token/{print $1}')" \
    | awk '/^token/{print $2}')

  [[ -z "$TOKEN" ]] && die "Failed to retrieve admin-user token."

  info "=== Setup Complete ==="
  echo ""
  echo "Dashboard URL : https://${NODE_IP}:$(kubectl get svc kubernetes-dashboard \
    -n kubernetes-dashboard \
    -o jsonpath='{.spec.ports[0].nodePort}')"
  echo ""
  echo "Login Token   :"
  echo "$TOKEN"
fi
