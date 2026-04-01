#!/usr/bin/env bash
# Main orchestrator: parse args, run phases in order
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/quota.sh"
source "${LIB_DIR}/cluster.sh"
source "${LIB_DIR}/features.sh"
source "${LIB_DIR}/cert-manager.sh"
source "${LIB_DIR}/nfd.sh"
source "${LIB_DIR}/gpu-operator.sh"
source "${LIB_DIR}/dra-driver.sh"
source "${LIB_DIR}/smoke-test.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Create an OpenShift cluster with NVIDIA GPUs and DRA support.

Required:
  --cluster-name NAME     Cluster name
  --cloud CLOUD            Cloud provider: gcp, aws
  --gpu GPU                GPU type: t4, l4, a100, h100
  --pull-secret PATH       Path to pull-secret.json

Optional:
  --ocp-version VERSION    OpenShift version (default: 4.21.0)
  --openshift-install PATH Path to openshift-install binary (auto-downloaded if not found)
  --mig-mode MODE          MIG mode: timeslicing, dynamicmig (default: timeslicing)
                           Ignored for non-MIG GPUs (T4)
  --region REGION          Cloud region (auto-selected if not specified)
  --worker-zone ZONE       Worker node zone (auto-selected if not specified)
  --ssh-key PATH           SSH public key path (default: ~/.ssh/id_rsa.pub or ~/.ssh/id_ed25519.pub)
  --install-dir DIR        Directory for openshift-install artifacts (default: /tmp/ocp-<cluster-name>)
  --skip-cluster           Skip cluster creation (use existing cluster)
  --skip-to PHASE          Skip to a specific phase (feature-gates, cert-manager, nfd, gpu-operator, dra-driver, smoke-test)
  --nfd-version VERSION    NFD chart version (default: 0.17.3)
  --gpu-operator-version V GPU Operator chart version (default: v25.10.1)
  --dra-driver-version V   DRA Driver chart version (default: 25.12.0)
  --smoke-test             Run smoke test after setup
  -h, --help               Show this help

Examples:
  # T4 on AWS (cheapest)
  $(basename "$0") --cluster-name my-test --cloud aws --gpu t4 --pull-secret ~/.pull-secret.json

  # A100 on GCP with DynamicMIG
  $(basename "$0") --cluster-name mig-test --cloud gcp --gpu a100 --pull-secret ~/.pull-secret.json --mig-mode dynamicmig

  # H100 on AWS, skip to DRA driver install (cluster already exists)
  $(basename "$0") --cluster-name gpu-test --cloud aws --gpu h100 --pull-secret ~/.pull-secret.json --skip-to dra-driver
EOF
}

# Parse arguments
CLUSTER_NAME=""
CLOUD=""
GPU=""
PULL_SECRET=""
MIG_MODE="timeslicing"
REGION=""
WORKER_ZONE=""
SSH_KEY=""
INSTALL_DIR=""
SKIP_CLUSTER=false
SKIP_TO=""
SMOKE_TEST=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
        --cloud) CLOUD="$2"; shift 2 ;;
        --gpu) GPU="$2"; shift 2 ;;
        --pull-secret) PULL_SECRET="$2"; shift 2 ;;
        --ocp-version) OCP_VERSION="$2"; shift 2 ;;
        --openshift-install) OPENSHIFT_INSTALL="$2"; shift 2 ;;
        --nfd-version) NFD_CHART_VERSION="$2"; shift 2 ;;
        --gpu-operator-version) GPU_OPERATOR_CHART_VERSION="$2"; shift 2 ;;
        --dra-driver-version) DRA_DRIVER_CHART_VERSION="$2"; shift 2 ;;
        --mig-mode) MIG_MODE="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --worker-zone) WORKER_ZONE="$2"; shift 2 ;;
        --ssh-key) SSH_KEY="$2"; shift 2 ;;
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --skip-cluster) SKIP_CLUSTER=true; shift ;;
        --skip-to) SKIP_TO="$2"; shift 2 ;;
        --smoke-test) SMOKE_TEST=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# Validate required args
if [[ -z "$CLUSTER_NAME" || -z "$CLOUD" || -z "$GPU" || -z "$PULL_SECRET" ]]; then
    log_error "Missing required arguments"
    usage
    exit 1
fi

# Validate cloud
if [[ "$CLOUD" != "gcp" && "$CLOUD" != "aws" ]]; then
    log_error "Invalid cloud: $CLOUD (must be gcp or aws)"
    exit 1
fi

# Validate GPU
if [[ "$GPU" != "t4" && "$GPU" != "l4" && "$GPU" != "a100" && "$GPU" != "h100" ]]; then
    log_error "Invalid GPU: $GPU (must be t4, l4, a100, or h100)"
    exit 1
fi

# Validate cloud+GPU combo
if [[ "$GPU" == "l4" && "$CLOUD" != "gcp" ]]; then
    log_error "L4 is only available on GCP (g2-standard-4)"
    exit 1
fi

# Validate pull secret exists
if [[ ! -f "$PULL_SECRET" ]]; then
    log_error "Pull secret not found: $PULL_SECRET"
    exit 1
fi

# Auto-resolve defaults
if [[ -z "$REGION" ]]; then
    REGION=$(get_default_region "$CLOUD" "$GPU")
fi
if [[ -z "$WORKER_ZONE" ]]; then
    WORKER_ZONE=$(get_default_worker_zone "$CLOUD" "$GPU")
fi
if [[ -z "$SSH_KEY" ]]; then
    if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
        SSH_KEY="$HOME/.ssh/id_ed25519.pub"
    elif [[ -f "$HOME/.ssh/id_rsa.pub" ]]; then
        SSH_KEY="$HOME/.ssh/id_rsa.pub"
    else
        log_error "No SSH public key found. Provide one with --ssh-key"
        exit 1
    fi
fi
if [[ -z "$INSTALL_DIR" ]]; then
    INSTALL_DIR="/tmp/ocp-${CLUSTER_NAME}"
fi

# Resolve openshift-install binary
resolve_openshift_install "$OCP_VERSION"

# Auto-gate MIG mode
MIG_MODE=$(get_mig_mode "$GPU" "$MIG_MODE")

# Resolve instance type for display
INSTANCE_TYPE=$(get_instance_type "$CLOUD" "$GPU")

# ============================================================
# Summary
# ============================================================
log_phase "Cluster Setup Summary"
echo "  Cluster:       ${CLUSTER_NAME}"
echo "  Cloud:         ${CLOUD}"
echo "  GPU:           ${GPU} (${INSTANCE_TYPE})"
echo "  Region:        ${REGION}"
echo "  Worker Zone:   ${WORKER_ZONE}"
echo "  MIG Mode:      ${MIG_MODE}"
echo "  Pull Secret:   ${PULL_SECRET}"
echo "  SSH Key:       ${SSH_KEY}"
echo "  OCP Version:   ${OCP_VERSION}"
echo "  Installer:     ${OPENSHIFT_INSTALL}"
echo "  Install Dir:   ${INSTALL_DIR}"
echo ""
echo "  Component Versions:"
echo "    NFD:            ${NFD_CHART_VERSION}"
echo "    GPU Operator:   ${GPU_OPERATOR_CHART_VERSION}"
echo "    DRA Driver:     ${DRA_DRIVER_CHART_VERSION}"
echo ""

# ============================================================
# Phase execution with skip-to support
# ============================================================
PHASES=("cluster" "feature-gates" "cert-manager" "nfd" "gpu-operator" "dra-driver" "smoke-test")

should_run_phase() {
    local phase="$1"
    if [[ -n "$SKIP_TO" ]]; then
        if [[ "$phase" == "$SKIP_TO" ]]; then
            SKIP_TO=""  # Found the target, run this and everything after
            return 0
        fi
        return 1
    fi
    if [[ "$SKIP_CLUSTER" == "true" && "$phase" == "cluster" ]]; then
        return 1
    fi
    if [[ "$phase" == "smoke-test" && "$SMOKE_TEST" != "true" ]]; then
        return 1
    fi
    return 0
}

# Set KUBECONFIG if skipping cluster creation
if [[ "$SKIP_CLUSTER" == "true" || -n "$SKIP_TO" ]]; then
    if [[ -f "${INSTALL_DIR}/auth/kubeconfig" ]]; then
        export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"
        log_info "Using existing KUBECONFIG: ${KUBECONFIG}"
    else
        log_error "No kubeconfig found at ${INSTALL_DIR}/auth/kubeconfig"
        log_error "Set KUBECONFIG env var or provide --install-dir"
        exit 1
    fi
fi

# Run phases
if should_run_phase "cluster"; then
    check_quota "$CLOUD" "$GPU" "$REGION"
    create_cluster "$CLOUD" "$CLUSTER_NAME" "$GPU" "$REGION" "$WORKER_ZONE" "$PULL_SECRET" "$SSH_KEY" "$INSTALL_DIR"
fi

if should_run_phase "feature-gates"; then
    enable_dra_feature_gates "$MIG_MODE"
fi

if should_run_phase "cert-manager"; then
    install_cert_manager
fi

if should_run_phase "nfd"; then
    install_nfd
fi

if should_run_phase "gpu-operator"; then
    install_gpu_operator "$MIG_MODE"
fi

if should_run_phase "dra-driver"; then
    install_dra_driver "$GPU" "$MIG_MODE"
fi

if should_run_phase "smoke-test"; then
    run_smoke_test "$MIG_MODE"
fi

log_phase "Setup Complete!"
echo "  KUBECONFIG=${KUBECONFIG:-${INSTALL_DIR}/auth/kubeconfig}"
echo ""
echo "  Next steps:"
echo "    export KUBECONFIG=${KUBECONFIG:-${INSTALL_DIR}/auth/kubeconfig}"
echo "    oc get nodes"
echo "    oc get deviceclass"
echo "    oc get resourceslice"
