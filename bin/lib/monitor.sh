#!/usr/bin/env bash
# Active monitoring helpers: wait loops with timeout, log surfacing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

DEFAULT_TIMEOUT=900   # 15 minutes
DEFAULT_INTERVAL=15   # 15 seconds

# Generic wait-for-condition loop
# Usage: wait_for "description" timeout_secs interval_secs check_command
wait_for() {
    local description="$1"
    local timeout="${2:-$DEFAULT_TIMEOUT}"
    local interval="${3:-$DEFAULT_INTERVAL}"
    shift 3
    local cmd=("$@")

    log_info "Waiting for: ${description} (timeout: ${timeout}s)"
    local elapsed=0
    while (( elapsed < timeout )); do
        if "${cmd[@]}" &>/dev/null; then
            log_success "$description"
            return 0
        fi
        sleep "$interval"
        elapsed=$(( elapsed + interval ))
        echo -ne "\r  Elapsed: ${elapsed}s / ${timeout}s"
    done
    echo ""
    log_error "Timed out waiting for: ${description}"
    return 1
}

# Wait for pods matching a label to be Running in a namespace
wait_for_pods_running() {
    local namespace="$1" label="$2" timeout="${3:-$DEFAULT_TIMEOUT}"
    local description="pods with label ${label} in ${namespace} to be Running"

    log_info "Waiting for: ${description} (timeout: ${timeout}s)"
    local elapsed=0
    while (( elapsed < timeout )); do
        local total ready
        total=$(oc get pods -n "$namespace" -l "$label" --no-headers 2>/dev/null | wc -l)
        ready=$(oc get pods -n "$namespace" -l "$label" --no-headers 2>/dev/null | grep -c "Running" || true)
        if (( total > 0 && total == ready )); then
            log_success "$description (${ready}/${total})"
            return 0
        fi
        sleep "$DEFAULT_INTERVAL"
        elapsed=$(( elapsed + DEFAULT_INTERVAL ))
        echo -ne "\r  Elapsed: ${elapsed}s — pods: ${ready:-0}/${total:-0} Running"
    done
    echo ""
    log_error "Timed out: ${description}"
    log_info "Current pod status:"
    oc get pods -n "$namespace" -l "$label" 2>/dev/null || true
    log_info "Recent events:"
    oc get events -n "$namespace" --sort-by='.lastTimestamp' 2>/dev/null | tail -10 || true
    return 1
}

# Wait for all nodes to be Ready
wait_for_nodes_ready() {
    local timeout="${1:-$DEFAULT_TIMEOUT}" min_count="${2:-1}"
    local description="at least ${min_count} worker node(s) to be Ready"

    log_info "Waiting for: ${description} (timeout: ${timeout}s)"
    local elapsed=0
    while (( elapsed < timeout )); do
        local ready
        ready=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | grep -c " Ready" || true)
        if (( ready >= min_count )); then
            log_success "$description (${ready} ready)"
            return 0
        fi
        sleep "$DEFAULT_INTERVAL"
        elapsed=$(( elapsed + DEFAULT_INTERVAL ))
        echo -ne "\r  Elapsed: ${elapsed}s — workers ready: ${ready:-0}/${min_count}"
    done
    echo ""
    log_error "Timed out: ${description}"
    log_info "Node status:"
    oc get nodes 2>/dev/null || true
    return 1
}

# Wait for MachineConfigPool rollout to complete
wait_for_mcp_rollout() {
    local timeout="${1:-1200}"  # 20 min default for MCP
    local description="MachineConfigPool rollout to complete"

    log_info "Waiting for: ${description} (timeout: ${timeout}s)"
    local elapsed=0
    while (( elapsed < timeout )); do
        local updating degraded
        updating=$(oc get mcp -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Updating")].status}{"\n"}{end}' 2>/dev/null | grep -c "True" || true)
        degraded=$(oc get mcp -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Degraded")].status}{"\n"}{end}' 2>/dev/null | grep -c "True" || true)

        if (( degraded > 0 )); then
            log_error "MachineConfigPool is Degraded!"
            oc get mcp 2>/dev/null || true
            return 1
        fi

        if (( updating == 0 )); then
            log_success "$description"
            return 0
        fi

        sleep 30
        elapsed=$(( elapsed + 30 ))
        echo -ne "\r  Elapsed: ${elapsed}s — MCPs still updating: ${updating}"
    done
    echo ""
    log_error "Timed out: ${description}"
    oc get mcp 2>/dev/null || true
    return 1
}

# Wait for a Kubernetes resource to exist
wait_for_resource() {
    local resource="$1" timeout="${2:-300}"
    local description="resource ${resource} to exist"

    wait_for "$description" "$timeout" "$DEFAULT_INTERVAL" \
        oc get "$resource"
}

# Monitor worker machine provisioning with zone fallback
# Returns 0 if worker is ready, 1 if all zones exhausted
monitor_worker_provisioning() {
    local cloud="$1" gpu="$2" timeout="${3:-1800}"  # 30 min default
    local zones zone_array current_zone_idx=0
    zones=$(get_zone_priority "$cloud" "$gpu")
    read -ra zone_array <<< "$zones"

    log_info "Monitoring worker provisioning (zones: ${zones})"
    local elapsed=0
    while (( elapsed < timeout )); do
        # Check if any worker node is Ready
        local ready
        ready=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | grep -c " Ready" || true)
        if (( ready > 0 )); then
            log_success "Worker node is Ready!"
            return 0
        fi

        # Check for failed machines
        local failed_machines
        failed_machines=$(oc get machines.machine.openshift.io -n openshift-machine-api \
            -l machine.openshift.io/cluster-api-machine-role=worker \
            -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for m in data.get('items', []):
    phase = m.get('status', {}).get('phase', '')
    name = m['metadata']['name']
    if phase == 'Failed':
        # Check for capacity errors in conditions
        conditions = m.get('status', {}).get('conditions', [])
        reason = ''
        for c in conditions:
            if 'capacity' in c.get('message', '').lower() or 'insufficient' in c.get('message', '').lower() or 'stockout' in c.get('message', '').lower():
                reason = c.get('message', '')
        print(f'{name}|{reason}')
" 2>/dev/null || true)

        if [[ -n "$failed_machines" ]]; then
            log_warn "Failed machine(s) detected:"
            echo "$failed_machines"

            # Check if it's a capacity issue
            if echo "$failed_machines" | grep -qi "capacity\|insufficient\|stockout\|quota"; then
                current_zone_idx=$(( current_zone_idx + 1 ))
                if (( current_zone_idx >= ${#zone_array[@]} )); then
                    log_error "All zones exhausted. No capacity available for $gpu."
                    return 1
                fi
                local new_zone="${zone_array[$current_zone_idx]}"
                log_warn "Capacity issue detected. Switching to zone: ${new_zone}"

                # Get the worker MachineSet name
                local machineset
                machineset=$(oc get machinesets.machine.openshift.io -n openshift-machine-api \
                    -l machine.openshift.io/cluster-api-machine-role=worker \
                    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

                if [[ -n "$machineset" ]]; then
                    # Delete failed machines
                    oc get machines.machine.openshift.io -n openshift-machine-api \
                        -l machine.openshift.io/cluster-api-machine-role=worker \
                        -o name 2>/dev/null | while read -r m; do
                        local phase
                        phase=$(oc get "$m" -n openshift-machine-api -o jsonpath='{.status.phase}' 2>/dev/null || true)
                        if [[ "$phase" == "Failed" ]]; then
                            log_info "Deleting failed machine: $m"
                            oc delete "$m" -n openshift-machine-api 2>/dev/null || true
                        fi
                    done

                    # Patch MachineSet with new zone
                    if [[ "$cloud" == "gcp" ]]; then
                        oc patch machineset.machine.openshift.io "$machineset" -n openshift-machine-api --type=merge \
                            -p "{\"spec\":{\"template\":{\"spec\":{\"providerSpec\":{\"value\":{\"zone\":\"${new_zone}\"}}}}}}" 2>/dev/null
                    elif [[ "$cloud" == "aws" ]]; then
                        local new_region
                        new_region=$(get_region_from_zone "$cloud" "$new_zone")
                        oc patch machineset.machine.openshift.io "$machineset" -n openshift-machine-api --type=merge \
                            -p "{\"spec\":{\"template\":{\"spec\":{\"providerSpec\":{\"value\":{\"placement\":{\"availabilityZone\":\"${new_zone}\",\"region\":\"${new_region}\"}}}}}}}}" 2>/dev/null
                    fi
                    log_info "MachineSet patched to zone: ${new_zone}. Waiting for new machine..."
                fi
            fi
        fi

        sleep 30
        elapsed=$(( elapsed + 30 ))
        echo -ne "\r  Elapsed: ${elapsed}s — waiting for worker node..."
    done
    echo ""
    log_error "Timed out waiting for worker node"
    oc get machines.machine.openshift.io -n openshift-machine-api 2>/dev/null || true
    return 1
}

# Check worker machine health (called after each phase)
verify_worker_healthy() {
    local ready
    ready=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | grep -c " Ready" || true)
    if (( ready == 0 )); then
        log_error "No worker nodes are Ready!"
        oc get nodes 2>/dev/null || true
        return 1
    fi
    log_success "Worker node healthy (${ready} Ready)"
    return 0
}
