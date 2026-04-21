#!/usr/bin/env bash
# Teardown: uninstall GPU/DRA resources or destroy entire cluster
set -uo pipefail
# NOTE: no 'set -e' — teardown must continue even if individual deletions fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/config.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --resources-only        Only remove GPU/DRA resources (keep cluster)
  --install-dir DIR       Cluster install directory (default: /tmp/ocp-<name>)
  --cluster-name NAME     Cluster name (for destroy)
  --openshift-install PATH  Path to openshift-install binary
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
        --openshift-install) OPENSHIFT_INSTALL="$2"; shift 2 ;;
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

# Set GCP credentials if the service account key exists
GCP_KEY="$HOME/.gcp/ocp-dev/osServiceAccount.json"
if [[ -f "$GCP_KEY" ]]; then
    export GOOGLE_APPLICATION_CREDENTIALS="$GCP_KEY"
fi

# Delete a namespace without blocking — patch finalizers if stuck
delete_namespace() {
    local ns="$1"
    local timeout="${2:-60}"

    oc delete namespace "$ns" --wait=false 2>/dev/null || true

    # Wait briefly for normal deletion
    local elapsed=0
    while (( elapsed < timeout )); do
        if ! oc get namespace "$ns" &>/dev/null; then
            return 0
        fi
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done

    # Still stuck — clear finalizers
    log_warn "Namespace $ns stuck in Terminating, clearing finalizers..."
    oc get ns "$ns" -o json 2>/dev/null \
        | python3 -c 'import sys,json; d=json.load(sys.stdin); d["spec"]["finalizers"]=[]; print(json.dumps(d))' \
        | oc replace --raw "/api/v1/namespaces/${ns}/finalize" -f - 2>/dev/null || true
}

uninstall_resources() {
    log_phase "Checking for GPU/DRA Resources"

    local has_gpu_resources=false

    # Check if any GPU/DRA namespaces exist
    if oc get namespace nvidia-dra-driver-gpu &>/dev/null; then
        has_gpu_resources=true
        log_info "Uninstalling DRA driver..."
        helm uninstall nvidia-dra-driver-gpu -n nvidia-dra-driver-gpu 2>/dev/null || true
        delete_namespace nvidia-dra-driver-gpu 30
    fi

    if oc get namespace nvidia-gpu-operator &>/dev/null; then
        has_gpu_resources=true
        log_info "Removing GPU operator..."
        oc delete clusterpolicy --all --wait=false 2>/dev/null || true
        sleep 5
        helm uninstall gpu-operator -n nvidia-gpu-operator 2>/dev/null || true
        delete_namespace nvidia-gpu-operator 30
    fi

    if oc get namespace node-feature-discovery &>/dev/null; then
        has_gpu_resources=true
        log_info "Removing NFD..."
        helm uninstall node-feature-discovery -n node-feature-discovery 2>/dev/null || true
        delete_namespace node-feature-discovery 30
    fi

    # Clean up NVIDIA CRDs if any exist
    local nvidia_crds
    nvidia_crds=$(oc get crd -o name 2>/dev/null | grep -E 'nvidia\.com|gpu-operator' || true)
    if [[ -n "$nvidia_crds" ]]; then
        has_gpu_resources=true
        log_info "Cleaning up NVIDIA CRDs..."
        echo "$nvidia_crds" | xargs -r oc delete 2>/dev/null || true
    fi

    if [[ "$has_gpu_resources" == "true" ]]; then
        log_success "GPU/DRA resource cleanup complete"
        log_info "Remaining NVIDIA pods:"
        oc get pods -A 2>/dev/null | grep -i nvidia || echo "  (none)"
    else
        log_info "No GPU/DRA resources found — nothing to clean up"
    fi
}

destroy_cluster() {
    log_phase "Destroying Cluster"
    log_info "Cluster destruction typically takes 10-20 minutes (stopping instances, removing load balancers, disks, and networking)"

    if [[ -z "$INSTALL_DIR" ]]; then
        log_error "Provide --install-dir or --cluster-name to destroy cluster"
        exit 1
    fi

    # Try to resolve openshift-install without downloading (cluster metadata has OCP version)
    if [[ ! -x "$OPENSHIFT_INSTALL" ]]; then
        if [[ -x "${TOOLS_DIR}/openshift-install" ]]; then
            OPENSHIFT_INSTALL="${TOOLS_DIR}/openshift-install"
        elif command -v openshift-install &>/dev/null; then
            OPENSHIFT_INSTALL="$(command -v openshift-install)"
        else
            log_error "openshift-install not found. Provide OPENSHIFT_INSTALL env var or place binary in bin/tools/"
            return 1
        fi
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
    # Only clean up DRA resources if any exist — don't waste time checking on non-DRA clusters
    if oc get namespace nvidia-dra-driver-gpu nvidia-gpu-operator node-feature-discovery &>/dev/null 2>&1; then
        uninstall_resources
    fi
    destroy_cluster
fi
