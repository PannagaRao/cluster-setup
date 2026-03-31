#!/usr/bin/env bash
# Install NVIDIA DRA Driver with MIG mode gated by GPU capability
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/monitor.sh"

TEMPLATE_DIR="$(cd "${SCRIPT_DIR}/../../templates" && pwd)"

install_dra_driver() {
    local gpu="$1" mig_mode="${2:-timeslicing}"

    # Auto-gate MIG based on GPU capability
    mig_mode=$(get_mig_mode "$gpu" "$mig_mode")

    log_phase "Installing NVIDIA DRA Driver (mode: ${mig_mode})"

    local namespace="nvidia-dra-driver-gpu"

    # Create namespace
    oc create namespace "$namespace" 2>/dev/null || true

    # Grant SCC
    for sa in nvidia-dra-driver-gpu-service-account-controller nvidia-dra-driver-gpu-service-account-kubeletplugin compute-domain-daemon-service-account; do
        oc adm policy add-scc-to-user privileged -n "$namespace" -z "$sa" 2>/dev/null || true
    done

    # Ensure nvidia helm repo is available (same repo as GPU operator)
    helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>/dev/null || true
    helm repo update nvidia 2>/dev/null || true

    # Select values file based on MIG mode
    local values_file
    if [[ "$mig_mode" == "dynamicmig" ]]; then
        values_file="${TEMPLATE_DIR}/helm-values-dynamicmig.yaml"
    else
        values_file="${TEMPLATE_DIR}/helm-values-timeslicing.yaml"
    fi

    if [[ ! -f "$values_file" ]]; then
        log_error "Helm values file not found: ${values_file}"
        return 1
    fi

    # Set feature gate overrides based on mode
    local set_overrides=""
    if [[ "$mig_mode" == "timeslicing" ]]; then
        set_overrides="--set featureGates.DynamicMIG=false --set featureGates.TimeSlicingSettings=true"
    else
        set_overrides="--set featureGates.DynamicMIG=true"
    fi

    # Install DRA driver
    # shellcheck disable=SC2086
    helm upgrade --install nvidia-dra-driver-gpu nvidia/nvidia-dra-driver-gpu \
        --namespace "$namespace" \
        --version "$DRA_DRIVER_CHART_VERSION" \
        -f "$values_file" \
        $set_overrides \
        --wait --timeout 10m

    log_success "DRA driver helm chart installed (mode: ${mig_mode})"

    # Wait for DRA driver pods
    wait_for_pods_running "$namespace" "app.kubernetes.io/name=nvidia-dra-driver-gpu" 300

    # Verify DeviceClass exists
    log_info "Checking for DeviceClass..."
    wait_for_resource "deviceclass" 120

    log_info "DeviceClasses:"
    oc get deviceclass 2>/dev/null || true

    # Verify ResourceSlice exists (devices are published)
    log_info "Checking for ResourceSlices..."
    wait_for_resource "resourceslice" 120

    local slice_count
    slice_count=$(oc get resourceslice --no-headers 2>/dev/null | wc -l)
    log_success "DRA driver ready: ${slice_count} ResourceSlice(s) found"

    log_info "ResourceSlices:"
    oc get resourceslice 2>/dev/null || true
}
