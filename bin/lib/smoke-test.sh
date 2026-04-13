#!/usr/bin/env bash
# Smoke test: verify ResourceSlice, DeviceClass, and MIG counters
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/monitor.sh"

# Verify DRA resource publication and MIG counters if applicable
run_smoke_test() {
    local mig_mode="${1:-timeslicing}"

    log_phase "Running Smoke Test"
    log_info "Verifying DRA resource publication and GPU availability"

    # Check DeviceClass CRDs exist
    log_info "Checking DeviceClass..."
    local device_classes
    device_classes=$(oc get deviceclass --no-headers 2>/dev/null | wc -l)
    if (( device_classes > 0 )); then
        log_success "DeviceClass(es) found: ${device_classes}"
    else
        log_error "No DeviceClass resources found"
        return 1
    fi

    # Check ResourceSlice CRDs exist
    log_info "Checking ResourceSlice..."
    local resource_slices
    resource_slices=$(oc get resourceslice --no-headers 2>/dev/null | wc -l)
    if (( resource_slices > 0 )); then
        log_success "ResourceSlice(s) found: ${resource_slices}"
    else
        log_error "No ResourceSlice resources found"
        return 1
    fi

    # Check if DynamicMIG is enabled in DRA driver config
    local dynamic_mig_enabled=false
    if oc get secret -n nvidia-dra-driver-gpu nvidia-dra-driver-gpu-values 2>/dev/null | grep -q .; then
        local dra_values
        dra_values=$(oc get secret -n nvidia-dra-driver-gpu nvidia-dra-driver-gpu-values -o jsonpath='{.data.values\.yaml}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        if echo "$dra_values" | grep -qi "DynamicMIG.*true"; then
            dynamic_mig_enabled=true
        fi
    fi

    # For DynamicMIG-enabled drivers, verify SharedCounterSets and CounterSets
    if [[ "$dynamic_mig_enabled" == "true" ]]; then
        log_info "DynamicMIG mode detected in DRA driver — checking for SharedCounterSets and CounterSets..."

        local shared_counters
        shared_counters=$(oc get resourceslice -o json 2>/dev/null | grep -ci "sharedcounterset" || true)

        local counter_sets
        counter_sets=$(oc get resourceslice -o json 2>/dev/null | grep -ci "counterset" || true)

        # If counters missing, restart kubelet-plugin to re-publish with counter data
        if (( shared_counters == 0 && counter_sets == 0 )); then
            log_warn "No SharedCounterSet or CounterSet found — restarting DRA driver kubelet-plugin to re-publish..."
            oc delete pod -n nvidia-dra-driver-gpu -l app=nvidia-dra-driver-gpu-kubelet-plugin --wait=false 2>/dev/null || true
            sleep 5
            log_info "Waiting for kubelet-plugin to restart..."
            wait_for_pods_running "nvidia-dra-driver-gpu" "app=nvidia-dra-driver-gpu-kubelet-plugin" 300

            # Re-check counters after restart
            sleep 3
            shared_counters=$(oc get resourceslice -o json 2>/dev/null | grep -ci "sharedcounterset" || true)
            counter_sets=$(oc get resourceslice -o json 2>/dev/null | grep -ci "counterset" || true)
        fi

        if (( shared_counters > 0 )); then
            log_success "SharedCounterSet(s) found: ${shared_counters}"
        else
            log_warn "No SharedCounterSet found in ResourceSlice"
        fi

        if (( counter_sets > 0 )); then
            log_success "CounterSet(s) found: ${counter_sets}"
        else
            log_warn "No CounterSet found in ResourceSlice"
        fi
    fi

    log_success "Smoke test passed: DRA resources are published"
    log_info "ResourceSlice and DeviceClass are ready for GPU workloads"
}
