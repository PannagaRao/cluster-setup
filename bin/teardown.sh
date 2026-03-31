#!/usr/bin/env bash
# Teardown: uninstall GPU/DRA resources or destroy entire cluster
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/config.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --resources-only        Only remove GPU/DRA resources (keep cluster)
  --install-dir DIR       Cluster install directory (default: /tmp/ocp-<name>)
  --cluster-name NAME     Cluster name (for destroy)
  -h, --help              Show this help
EOF
}

RESOURCES_ONLY=false
INSTALL_DIR=""
CLUSTER_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --resources-only) RESOURCES_ONLY=true; shift ;;
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$INSTALL_DIR" && -n "$CLUSTER_NAME" ]]; then
    INSTALL_DIR="/tmp/ocp-${CLUSTER_NAME}"
fi

# Set KUBECONFIG
if [[ -n "$INSTALL_DIR" && -f "${INSTALL_DIR}/auth/kubeconfig" ]]; then
    export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"
fi

uninstall_resources() {
    log_phase "Removing GPU/DRA Resources"

    # Uninstall DRA driver
    log_info "Uninstalling DRA driver..."
    helm uninstall nvidia-dra-driver-gpu -n nvidia-dra-driver-gpu 2>/dev/null || true
    sleep 10
    oc delete namespace nvidia-dra-driver-gpu 2>/dev/null || true

    # Delete GPU operator ClusterPolicy
    log_info "Removing GPU operator..."
    oc delete clusterpolicy --all 2>/dev/null || true
    sleep 20
    helm uninstall gpu-operator -n nvidia-gpu-operator 2>/dev/null || true
    sleep 10
    oc delete namespace nvidia-gpu-operator 2>/dev/null || true

    # Uninstall NFD
    log_info "Removing NFD..."
    helm uninstall node-feature-discovery -n node-feature-discovery 2>/dev/null || true
    oc delete namespace node-feature-discovery 2>/dev/null || true

    # Clean up NVIDIA CRDs
    log_info "Cleaning up CRDs..."
    oc get crd -o name 2>/dev/null | grep -i nvidia | xargs -r oc delete 2>/dev/null || true

    log_success "Resource cleanup complete"

    # Verify
    log_info "Remaining NVIDIA pods:"
    oc get pods -A 2>/dev/null | grep -i nvidia || echo "  (none)"
}

destroy_cluster() {
    log_phase "Destroying Cluster"

    if [[ -z "$INSTALL_DIR" ]]; then
        log_error "Provide --install-dir or --cluster-name to destroy cluster"
        exit 1
    fi

    if [[ ! -f "${INSTALL_DIR}/metadata.json" ]]; then
        log_error "No cluster metadata found at ${INSTALL_DIR}/metadata.json"
        exit 1
    fi

    # Tail the install log in the background so destroy progress is visible
    touch "${INSTALL_DIR}/.openshift_install.log"
    tail -f "${INSTALL_DIR}/.openshift_install.log" &
    local tail_pid=$!

    "$OPENSHIFT_INSTALL" destroy cluster --dir="$INSTALL_DIR" --log-level=debug

    kill "$tail_pid" 2>/dev/null || true
    log_success "Cluster destroyed"
}

# Execute
if [[ "$RESOURCES_ONLY" == "true" ]]; then
    uninstall_resources
else
    uninstall_resources
    destroy_cluster
fi
