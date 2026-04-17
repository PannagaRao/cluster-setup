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
    helm install gpu-operator nvidia/gpu-operator \
        --namespace "$namespace" \
        --version "$GPU_OPERATOR_CHART_VERSION" \
        --set "operator.defaultRuntime=crio" \
        --set "operator.use_ocp_driver_toolkit=true" \
        --set "platform.openshift=true" \
        --set "devicePlugin.enabled=false" \
        --set "dra.enabled=true" \
        --set "dra.structuredParameters.enabled=true" \
        $mig_set

    log_success "GPU Operator helm chart installed"

    # Grant SCC to service accounts after install (SAs are created by the helm chart)
    log_info "Granting SCC to GPU Operator service accounts..."
    sleep 10
    local service_accounts=(
        "default"
        "gpu-operator"
        "nvidia-driver-daemonset"
        "nvidia-container-toolkit-daemonset"
        "nvidia-operator-validator"
        "gpu-feature-discovery"
        "node-feature-discovery"
    )
    for sa in "${service_accounts[@]}"; do
        oc adm policy add-scc-to-user privileged -n "$namespace" -z "$sa" 2>/dev/null || true
    done

    # Check for driver ImagePullBackOff — nightly/candidate builds may not have
    # a pre-built driver image for the current RHCOS version.
    log_info "Waiting for GPU driver pod to start (checking for image pull issues)..."
    local drv_check=0
    while (( drv_check < 180 )); do
        local pull_err
        pull_err=$(oc get pods -n "$namespace" --no-headers 2>/dev/null \
            | grep "nvidia-driver-daemonset" | grep -i "ImagePullBackOff\|ErrImagePull" || true)
        if [[ -n "$pull_err" ]]; then
            local current_driver
            current_driver=$(oc get clusterpolicy cluster-policy -o jsonpath='{.spec.driver.version}' 2>/dev/null || echo "unknown")
            local rhcos_version
            rhcos_version=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].status.nodeInfo.osImage}' 2>/dev/null || echo "unknown")
            log_error "GPU driver image pull failed (driver: ${current_driver}, RHCOS: ${rhcos_version})"
            log_error "The default driver has no pre-built image for this RHCOS version."
            log_error "Fix: oc patch clusterpolicy cluster-policy --type merge -p '{\"spec\":{\"driver\":{\"version\":\"<compatible-version>\"}}}'"
            log_error "Check available versions at: https://catalog.ngc.nvidia.com/orgs/nvidia/containers/driver/tags"
            return 1
        fi
        # Check if driver pod is running (success)
        local running
        running=$(oc get pods -n "$namespace" --no-headers 2>/dev/null \
            | grep "nvidia-driver-daemonset" | grep -c "Running" || true)
        if (( running > 0 )); then
            break
        fi
        sleep 15
        drv_check=$(( drv_check + 15 ))
    done

    log_success "GPU Operator installed — driver compilation continues in background"
}
