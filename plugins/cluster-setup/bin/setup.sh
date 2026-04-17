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

# Notify user on failure — cluster may still be running
on_error() {
    echo ""
    log_error "Setup failed!"
    if [[ -n "${INSTALL_DIR:-}" && -f "${INSTALL_DIR}/metadata.json" ]]; then
        log_error "The cluster may still be running and incurring costs."
        log_error "To destroy:  /teardown or bash bin/teardown.sh --install-dir ${INSTALL_DIR}"
        if [[ -n "${CLUSTER_NAME:-}" && -n "${CLOUD:-}" && -n "${GPU:-}" ]]; then
            local resume_cmd="bash $(basename "$0") --cluster-name ${CLUSTER_NAME} --cloud ${CLOUD} --pull-secret ${PULL_SECRET:-<path>} --install-dir ${INSTALL_DIR} --skip-cluster"
            [[ "$GPU" != "none" ]] && resume_cmd+=" --gpu ${GPU}"
            [[ "${DRA:-false}" == "true" ]] && resume_cmd+=" --dra"
            log_error "To resume:   ${resume_cmd}"
        fi
    fi
}
trap on_error ERR

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Create an OpenShift cluster, optionally with NVIDIA GPUs and DRA support.

Required:
  --cluster-name NAME     Cluster name
  --cloud CLOUD            Cloud provider: gcp, aws
  --pull-secret PATH       Path to pull-secret.json

Instance type (at least one of --gpu or --instance-type required):
  --gpu GPU                GPU type: t4, l4 (GCP only), a100, h100
                           Auto-resolves instance type from GPU matrix
  --instance-type TYPE     Worker instance type (e.g. m6i.xlarge, g4dn.xlarge)
                           GPU auto-detected from instance family when --gpu omitted
  --no-gpu                 Skip GPU stack even on GPU-capable instances
  --workers N              Number of worker nodes (default: 1)

GPU/DRA stack (requires OCP 4.21+):
  --dra                    Install NVIDIA DRA stack (feature gates, cert-manager,
                           NFD, GPU Operator, DRA Driver). Requires --gpu and OCP 4.21+.
  --mig-mode MODE          MIG mode: timeslicing, dynamicmig (default: timeslicing)
                           Ignored for non-MIG GPUs (T4, L4). Requires --dra.
  --smoke-test             Run smoke test after DRA stack setup. Requires --dra.

Optional:
  --ocp-version VERSION    OpenShift version (default: 4.21.0)
  --openshift-install PATH Path to openshift-install binary (auto-downloaded if not found)
  --region REGION          Cloud region (auto-selected if not specified)
  --worker-zone ZONE       Worker node zone (auto-selected if not specified)
  --ssh-key PATH           SSH public key path (default: ~/.ssh/id_rsa.pub or ~/.ssh/id_ed25519.pub)
  --install-dir DIR        Directory for openshift-install artifacts (default: /tmp/ocp-<cluster-name>)
  --skip-cluster           Skip cluster creation (use existing cluster)
  --skip-to PHASE          Skip to a specific phase (feature-gates, cert-manager, nfd, gpu-operator, dra-driver, mig-activate, smoke-test)
  --nfd-version VERSION    NFD chart version (default: 0.17.3)
  --gpu-operator-version V GPU Operator chart version (default: v25.10.1)
  --dra-driver-version V   DRA Driver chart version (default: 25.12.0)
  -h, --help               Show this help

Examples:
  # General-purpose cluster (no GPU)
  $(basename "$0") --cluster-name my-cluster --cloud aws --pull-secret ~/.pull-secret.json --instance-type m6i.xlarge

  # T4 on AWS — GPU hardware only, no DRA stack
  $(basename "$0") --cluster-name my-test --cloud aws --gpu t4 --pull-secret ~/.pull-secret.json

  # T4 on AWS with full DRA stack (OCP 4.21+ required)
  $(basename "$0") --cluster-name my-test --cloud aws --gpu t4 --dra --pull-secret ~/.pull-secret.json

  # A100 on GCP with DRA stack and DynamicMIG
  $(basename "$0") --cluster-name mig-test --cloud gcp --gpu a100 --dra --pull-secret ~/.pull-secret.json --mig-mode dynamicmig

  # GPU-capable instance without GPU (e.g. manual GPU setup later)
  $(basename "$0") --cluster-name bare-gpu --cloud aws --pull-secret ~/.pull-secret.json --instance-type g4dn.xlarge --no-gpu
EOF
}

# Parse arguments
CLUSTER_NAME=""
CLOUD=""
GPU=""
INSTANCE_TYPE=""
NO_GPU=false
WORKERS=1
DRA=false
PULL_SECRET=""
MIG_MODE="timeslicing"
REGION=""
WORKER_ZONE=""
SSH_KEY=""
INSTALL_DIR=""
SKIP_CLUSTER=false
SKIP_TO=""
SMOKE_TEST=false
GENERATE_CONFIG_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
        --cloud) CLOUD="$2"; shift 2 ;;
        --gpu) GPU="$2"; shift 2 ;;
        --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
        --no-gpu) NO_GPU=true; shift ;;
        --workers) WORKERS="$2"; shift 2 ;;
        --dra) DRA=true; shift ;;
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
        --generate-config-only) GENERATE_CONFIG_ONLY=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# Validate required args
if [[ -z "$CLUSTER_NAME" || -z "$CLOUD" || -z "$PULL_SECRET" ]]; then
    log_error "Missing required arguments: --cluster-name, --cloud, and --pull-secret are required"
    usage
    exit 1
fi

# Normalize inputs
CLOUD=$(echo "$CLOUD" | tr '[:upper:]' '[:lower:]')
if [[ -n "$GPU" ]]; then
    GPU=$(echo "$GPU" | tr '[:upper:]' '[:lower:]')
fi

# Validate cloud
if [[ "$CLOUD" != "gcp" && "$CLOUD" != "aws" ]]; then
    log_error "Invalid cloud: $CLOUD (must be gcp or aws)"
    exit 1
fi

# Resolve relative pull secret path to absolute
if [[ -n "$PULL_SECRET" && "$PULL_SECRET" != /* ]]; then
    PULL_SECRET="${PWD}/${PULL_SECRET}"
fi

# Validate pull secret exists
if [[ ! -f "$PULL_SECRET" ]]; then
    log_error "Pull secret not found: $PULL_SECRET"
    exit 1
fi

# GCP requires GCP_PROJECT
if [[ "$CLOUD" == "gcp" && -z "$GCP_PROJECT" ]]; then
    log_error "GCP_PROJECT environment variable is required for GCP clusters"
    log_error "Set it with: export GCP_PROJECT=<your-project-id>"
    exit 1
fi

# Need at least --gpu or --instance-type
if [[ -z "$GPU" && -z "$INSTANCE_TYPE" ]]; then
    log_error "Either --gpu or --instance-type must be specified"
    usage
    exit 1
fi

# --no-gpu + --gpu conflict
if [[ "$NO_GPU" == "true" && -n "$GPU" ]]; then
    log_error "Cannot use both --gpu and --no-gpu"
    exit 1
fi

# --dra + --no-gpu conflict
if [[ "$DRA" == "true" && "$NO_GPU" == "true" ]]; then
    log_error "Cannot use both --dra and --no-gpu"
    exit 1
fi

# Normalize --mig-mode value
case "$MIG_MODE" in
    dynamicmig|dynamic|mig) MIG_MODE="dynamicmig" ;;
    *) MIG_MODE="timeslicing" ;;
esac

# Resolve GPU and instance type
if [[ "$NO_GPU" == "true" ]]; then
    # Explicit no-GPU: use provided instance type or default
    GPU="none"
    if [[ -z "$INSTANCE_TYPE" ]]; then
        INSTANCE_TYPE=$(get_instance_type "$CLOUD" none)
    fi
elif [[ -n "$GPU" && -n "$INSTANCE_TYPE" ]]; then
    # Both provided: validate consistency
    if [[ "$GPU" != "t4" && "$GPU" != "l4" && "$GPU" != "a100" && "$GPU" != "h100" ]]; then
        log_error "Invalid GPU: $GPU (must be t4, l4, a100, or h100)"
        exit 1
    fi
    detected=$(detect_gpu_from_instance_type "$CLOUD" "$INSTANCE_TYPE")
    if [[ "$detected" == "maybe-t4" ]]; then
        # GCP n1-* with --gpu t4 is valid (T4 accelerator attachment)
        if [[ "$GPU" != "t4" ]]; then
            log_error "Instance type ${INSTANCE_TYPE} (n1-*) only supports T4 accelerator, not ${GPU}"
            exit 1
        fi
    elif [[ "$detected" != "none" && "$detected" != "$GPU" ]]; then
        log_error "GPU mismatch: --gpu ${GPU} but instance type ${INSTANCE_TYPE} has ${detected}"
        exit 1
    elif [[ "$detected" == "none" ]]; then
        log_error "Instance type ${INSTANCE_TYPE} does not support GPU. Remove --gpu or pick a GPU instance"
        exit 1
    fi
elif [[ -n "$GPU" ]]; then
    # Only --gpu: resolve instance type from matrix
    if [[ "$GPU" != "t4" && "$GPU" != "l4" && "$GPU" != "a100" && "$GPU" != "h100" ]]; then
        log_error "Invalid GPU: $GPU (must be t4, l4, a100, or h100)"
        exit 1
    fi
    if [[ "$GPU" == "l4" && "$CLOUD" != "gcp" ]]; then
        log_error "L4 is only available on GCP (g2-standard-8)"
        exit 1
    fi
    INSTANCE_TYPE=$(get_instance_type "$CLOUD" "$GPU")
else
    # Only --instance-type: auto-detect GPU from instance family
    detected=$(detect_gpu_from_instance_type "$CLOUD" "$INSTANCE_TYPE")
    case "$detected" in
        maybe-t4)
            log_warn "Instance type ${INSTANCE_TYPE} (n1-*) can have a T4 accelerator. Use --gpu t4 to enable. Defaulting to no GPU."
            GPU="none"
            ;;
        none)
            GPU="none"
            ;;
        *)
            GPU="$detected"
            log_info "Auto-detected GPU: ${GPU} from instance type ${INSTANCE_TYPE}"
            ;;
    esac
fi

# Validate cloud+GPU combo
if [[ "$GPU" == "l4" && "$CLOUD" != "gcp" ]]; then
    log_error "L4 is only available on GCP (g2-standard-8)"
    exit 1
fi

# GPU enabled helper
has_gpu() { [[ "$GPU" != "none" ]]; }

# DRA stack helper
has_dra() { [[ "$DRA" == "true" ]]; }

# --dra requires GPU
if has_dra && ! has_gpu; then
    log_error "--dra requires a GPU (use --gpu or a GPU-capable --instance-type)"
    exit 1
fi

# --dra requires OCP 4.21+
if has_dra; then
    ocp_minor="${OCP_VERSION#4.}"
    ocp_minor="${ocp_minor%%.*}"
    if (( ocp_minor < 21 )); then
        log_error "DRA stack requires OCP 4.21+ (K8s 1.34+). Selected version: ${OCP_VERSION}"
        log_error "Remove --dra to provision the cluster with GPU hardware only."
        exit 1
    fi
fi

# --skip-to a DRA phase implies --dra
if [[ -n "$SKIP_TO" ]]; then
    case "$SKIP_TO" in
        feature-gates|cert-manager|nfd|gpu-operator|dra-driver|mig-activate|smoke-test)
            if ! has_gpu; then
                log_error "Cannot --skip-to ${SKIP_TO}: no GPU selected"
                exit 1
            fi
            DRA=true
            # Re-check OCP version for implied --dra
            ocp_minor="${OCP_VERSION#4.}"
            ocp_minor="${ocp_minor%%.*}"
            if (( ocp_minor < 21 )); then
                log_error "DRA stack requires OCP 4.21+ (K8s 1.34+). Selected version: ${OCP_VERSION}"
                exit 1
            fi
            ;;
    esac
fi

# --smoke-test requires --dra
if [[ "$SMOKE_TEST" == "true" ]] && ! has_dra; then
    log_warn "--smoke-test ignored: DRA stack not selected (smoke test checks DRA resources)"
    SMOKE_TEST=false
fi

# Auto-resolve defaults
if [[ -z "$REGION" ]]; then
    REGION=$(get_default_region "$CLOUD" "$GPU")
fi
if [[ -z "$WORKER_ZONE" ]]; then
    if [[ -n "$REGION" ]]; then
        for z in $(get_zone_priority "$CLOUD" "$GPU"); do
            if [[ "$(get_region_from_zone "$CLOUD" "$z")" == "$REGION" ]]; then
                WORKER_ZONE="$z"
                break
            fi
        done
        if [[ -z "$WORKER_ZONE" ]]; then
            WORKER_ZONE="${REGION}a"
        fi
    else
        WORKER_ZONE=$(get_default_worker_zone "$CLOUD" "$GPU")
    fi
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

# Auto-gate MIG mode (only when DRA stack is selected)
if has_dra; then
    MIG_MODE=$(get_mig_mode "$GPU" "$MIG_MODE")
fi

# ============================================================
# Summary
# ============================================================
log_phase "Cluster Setup Summary"
echo "  Cluster:       ${CLUSTER_NAME}"
echo "  Cloud:         ${CLOUD}"
echo "  Workers:       ${WORKERS}"
if has_dra; then
    echo "  GPU:           ${GPU} (${INSTANCE_TYPE})"
    echo "  DRA Stack:     yes"
    if [[ "$MIG_MODE" == "dynamicmig" ]]; then
        echo "  DynamicMIG:    yes"
    fi
elif has_gpu; then
    echo "  GPU:           ${GPU} (${INSTANCE_TYPE})"
else
    echo "  Instance Type: ${INSTANCE_TYPE}"
fi
echo "  Region:        ${REGION}"
echo "  Worker Zone:   ${WORKER_ZONE}"
echo "  Pull Secret:   ${PULL_SECRET}"
echo "  SSH Key:       ${SSH_KEY}"
echo "  OCP Version:   ${OCP_VERSION}"
echo "  Installer:     ${OPENSHIFT_INSTALL}"
echo "  Install Dir:   ${INSTALL_DIR}"
echo ""
if has_dra; then
    echo "  Component Versions:"
    echo "    NFD:            ${NFD_CHART_VERSION}"
    echo "    GPU Operator:   ${GPU_OPERATOR_CHART_VERSION}"
    echo "    DRA Driver:     ${DRA_DRIVER_CHART_VERSION}"
    echo ""
fi

# ============================================================
# Setup cloud credentials early — needed for quota check, config gen, and cluster creation
# ============================================================
if [[ "$CLOUD" == "gcp" ]]; then
    setup_gcp_service_account "$CLUSTER_NAME"
fi

# ============================================================
# Generate config only mode — produce install-config and exit
# ============================================================
if [[ "$GENERATE_CONFIG_ONLY" == "true" ]]; then
    mkdir -p "$INSTALL_DIR"
    generate_install_config "$CLOUD" "$CLUSTER_NAME" "$GPU" "$REGION" "$WORKER_ZONE" \
        "$PULL_SECRET" "$SSH_KEY" "$INSTALL_DIR" "$INSTANCE_TYPE"
    log_success "install-config.yaml generated at ${INSTALL_DIR}/install-config.yaml"
    exit 0
fi

# ============================================================
# Phase execution with skip-to support
# ============================================================
if has_dra; then
    PHASES=("cluster" "feature-gates" "cert-manager" "nfd" "gpu-operator" "dra-driver" "mig-activate" "smoke-test")
else
    PHASES=("cluster")
fi

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
    create_cluster "$CLOUD" "$CLUSTER_NAME" "$GPU" "$REGION" "$WORKER_ZONE" "$PULL_SECRET" "$SSH_KEY" "$INSTALL_DIR" "$INSTANCE_TYPE"
fi

# DRA stack phases (only when --dra is active)
if has_dra; then
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
        install_dra_driver "$GPU" "$MIG_MODE" "$CLOUD"
    fi

    if should_run_phase "mig-activate"; then
        if [[ "$MIG_MODE" == "dynamicmig" && "$GPU" == "a100" && ("$CLOUD" == "gcp" || "$CLOUD" == "aws") ]]; then
            activate_mig_cloud_vm
        fi
    fi

    if should_run_phase "smoke-test"; then
        run_smoke_test "$MIG_MODE"
    fi
elif has_gpu; then
    log_info "GPU hardware provisioned — DRA stack not selected"
fi

log_phase "Setup Complete!"
echo "  KUBECONFIG=${KUBECONFIG:-${INSTALL_DIR}/auth/kubeconfig}"
echo ""
echo "  Next steps:"
echo "    export KUBECONFIG=${KUBECONFIG:-${INSTALL_DIR}/auth/kubeconfig}"
echo "    oc get nodes"
if has_dra; then
    echo "    oc get deviceclass"
    echo "    oc get resourceslice"
elif has_gpu; then
    echo ""
    echo "  GPU hardware is provisioned. To install the DRA stack, re-run with:"
    echo "    $(basename "$0") --cluster-name ${CLUSTER_NAME} --cloud ${CLOUD} --gpu ${GPU} --dra --skip-cluster --install-dir ${INSTALL_DIR}"
fi
