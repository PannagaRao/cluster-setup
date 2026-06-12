#!/usr/bin/env bash
# Install DRA example driver for testing without GPU hardware
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/monitor.sh"

install_example_dra_driver() {
    local version="${1:-v0.3.0}"
    local num_devices="${2:-8}"
    local gpu_partitions="${3:-4}"

    log_phase "Installing DRA Example Driver (${version})"
    log_info "Simulated devices: ${num_devices} GPUs, ${gpu_partitions} partitions each"

    local namespace="dra-example-driver"

    # Create namespace
    oc create namespace "$namespace" 2>/dev/null || true

    # Grant SCC
    oc adm policy add-scc-to-user privileged -n "$namespace" -z dra-example-driver-service-account 2>/dev/null || true

    # Download and extract chart from source tarball
    local tarball="${TOOLS_DIR}/dra-example-driver-${version}.tar.gz"
    local chart_dir="/tmp/dra-example-driver-${version#v}/deployments/helm/dra-example-driver"

    if [[ ! -d "$chart_dir" ]]; then
        mkdir -p "$TOOLS_DIR"
        local url="https://github.com/kubernetes-sigs/dra-example-driver/archive/refs/tags/${version}.tar.gz"
        log_info "Downloading example driver chart: ${url}"
        if ! curl -fSL -o "$tarball" "$url" 2>/dev/null; then
            log_error "Failed to download dra-example-driver ${version}"
            return 1
        fi
        tar -xzf "$tarball" -C /tmp
        rm -f "$tarball"
    fi

    if [[ ! -d "$chart_dir" ]]; then
        log_error "Chart not found at ${chart_dir} after extraction"
        return 1
    fi

    # Helm install from local chart
    helm upgrade --install \
        --namespace "$namespace" \
        dra-example-driver \
        "$chart_dir" \
        --set kubeletPlugin.containers.plugin.securityContext.privileged=true \
        --set kubeletPlugin.numDevices="${num_devices}" \
        --set kubeletPlugin.gpuPartitions="${gpu_partitions}" \
        --wait \
        --timeout 10m

    log_success "DRA example driver installed"

    # Verify DeviceClass exists
    log_info "Checking for DeviceClass..."
    wait_for_resource "deviceclass" 120

    log_info "DeviceClasses:"
    oc get deviceclass 2>/dev/null || true

    # Verify ResourceSlice exists
    log_info "Checking for ResourceSlices..."
    wait_for_resource "resourceslice" 120

    local slice_count
    slice_count=$(oc get resourceslice --no-headers 2>/dev/null | wc -l)
    log_success "DRA example driver ready: ${slice_count} ResourceSlice(s), ${num_devices} GPUs × ${gpu_partitions} partitions"

    log_info "ResourceSlices:"
    oc get resourceslice 2>/dev/null || true
}
