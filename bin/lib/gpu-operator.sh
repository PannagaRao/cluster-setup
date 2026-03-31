#!/usr/bin/env bash
# Install NVIDIA GPU Operator with DRA enabled
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/monitor.sh"

install_gpu_operator() {
    local mig_mode="${1:-timeslicing}"

    log_phase "Installing NVIDIA GPU Operator"

    local namespace="nvidia-gpu-operator"

    # Create namespace
    oc create namespace "$namespace" 2>/dev/null || true

    # Grant SCC to all required service accounts
    local service_accounts=(
        "nvidia-gpu-operator"
        "nvidia-driver-daemonset"
        "nvidia-mig-manager"
        "nvidia-node-status-exporter"
        "nvidia-container-toolkit-daemonset"
        "nvidia-dcgm"
        "nvidia-dcgm-exporter"
        "nvidia-device-plugin-daemonset"
        "nvidia-operator-validator"
        "gpu-feature-discovery"
    )
    for sa in "${service_accounts[@]}"; do
        oc adm policy add-scc-to-user privileged -n "$namespace" -z "$sa" 2>/dev/null || true
    done

    # Add helm repo
    helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>/dev/null || true
    helm repo update nvidia 2>/dev/null || true

    # Build MIG flag — only enable mig.strategy=mixed when DynamicMIG is requested
    local mig_set=""
    if [[ "$mig_mode" == "dynamicmig" ]]; then
        mig_set='--set mig.strategy=mixed'
        log_info "MIG mode requested — setting mig.strategy=mixed"
    fi

    # Install GPU Operator
    # CRITICAL: devicePlugin.enabled=false when using DRA
    # shellcheck disable=SC2086
    helm upgrade --install gpu-operator nvidia/gpu-operator \
        --namespace "$namespace" \
        --version "$GPU_OPERATOR_CHART_VERSION" \
        --set "operator.defaultRuntime=crio" \
        --set "operator.use_ocp_driver_toolkit=true" \
        --set "platform.openshift=true" \
        --set "devicePlugin.enabled=false" \
        --set "dra.enabled=true" \
        --set "dra.structuredParameters.enabled=true" \
        $mig_set \
        --wait --timeout 10m

    log_success "GPU Operator helm chart installed"

    # Wait for GPU driver pod on the worker node (driver compilation takes 5-10 min)
    log_info "Waiting for GPU driver to compile and load (this can take 5-10 minutes)..."
    wait_for_pods_running "$namespace" "app=nvidia-driver-daemonset" 600

    # Verify GPU operator validator passes
    wait_for_pods_running "$namespace" "app=nvidia-operator-validator" 300

    log_success "GPU Operator installed and validated"
}
