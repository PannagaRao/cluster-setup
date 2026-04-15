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
# Fast polling (15s) for first 5min to catch capacity errors quickly
monitor_worker_provisioning() {
    local cloud="$1" gpu="$2" timeout="${3:-1800}" region="${4:-}"  # 30 min default
    local zones zone_array current_zone_idx=0
    zones=$(get_zone_priority "$cloud" "$gpu")

    # Filter zones to the user's chosen region
    if [[ -n "$region" ]]; then
        local filtered=""
        for z in $zones; do
            if [[ "$(get_region_from_zone "$cloud" "$z")" == "$region" ]]; then
                filtered="${filtered:+$filtered }$z"
            fi
        done
        if [[ -n "$filtered" ]]; then
            zones="$filtered"
        fi
    fi

    read -ra zone_array <<< "$zones"

    # Double the zone list so we try all zones twice before giving up
    local double_zones=("${zone_array[@]}" "${zone_array[@]}")

    log_info "Monitoring worker provisioning (zones: ${zones}, 2 passes)"
    local elapsed=0 poll_interval=15
    while (( elapsed < timeout )); do
        # Check if any worker node is Ready
        local ready
        ready=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | grep -c " Ready" || true)
        if (( ready > 0 )); then
            log_success "Worker node is Ready!"
            return 0
        fi

        # Check for failed or stuck worker machines
        local failed_machines
        failed_machines=$(oc get machines.machine.openshift.io -n openshift-machine-api \
                -o json 2>/dev/null | python3 -c "
import json, sys, datetime
data = json.load(sys.stdin)
for m in data.get('items', []):
    name = m['metadata']['name']
    if 'worker' not in name:
        continue
    phase = m.get('status', {}).get('phase', '')
    conditions = m.get('status', {}).get('conditions', [])
    msg = ' '.join(c.get('message', '') for c in conditions).lower()
    if phase == 'Failed':
        recoverable_patterns = ['insufficient', 'capacity', 'zone_resource_pool',
            'instance not found', 'instancemissing', \"can't find created instance\",
            'not available', 'machine type', 'resource not found', 'quota']
        if any(k in msg for k in recoverable_patterns):
            print(f'{name}|recoverable')
        else:
            print(f'{name}|fatal')
    elif phase in ('Provisioning', 'Provisioned', ''):
        # After 5 min, check if the instance was actually created (has providerID).
        # If not, it's stuck — likely zone/capacity issue.
        created = m.get('metadata', {}).get('creationTimestamp', '')
        provider_id = m.get('spec', {}).get('providerID', '') or ''
        if created:
            try:
                ct = datetime.datetime.fromisoformat(created.replace('Z', '+00:00'))
                age_min = (datetime.datetime.now(datetime.timezone.utc) - ct).total_seconds() / 60
                if age_min > 5 and not provider_id:
                    print(f'{name}|recoverable')
            except:
                pass
" 2>/dev/null || true)

        if [[ -n "$failed_machines" ]]; then
            if echo "$failed_machines" | grep -q "recoverable"; then
                current_zone_idx=$(( current_zone_idx + 1 ))
                if (( current_zone_idx >= ${#double_zones[@]} )); then
                    log_error "All zones tried twice for $gpu."
                    return 1
                fi
                local new_zone="${double_zones[$current_zone_idx]}"
                log_warn "Worker failed. Trying zone: ${new_zone} (attempt $(( current_zone_idx + 1 ))/${#double_zones[@]})"

                local machineset
                machineset=$(oc get machinesets.machine.openshift.io -n openshift-machine-api \
                                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

                if [[ -n "$machineset" ]]; then
                    delete_failed_worker_machines

                    if [[ "$cloud" == "aws" ]]; then
                        local new_region
                        new_region=$(get_region_from_zone "$cloud" "$new_zone")
                        oc patch machineset.machine.openshift.io "$machineset" -n openshift-machine-api --type=merge \
                            -p "{\"spec\":{\"template\":{\"spec\":{\"providerSpec\":{\"value\":{\"placement\":{\"availabilityZone\":\"${new_zone}\",\"region\":\"${new_region}\"}}}}}}}}" 2>/dev/null || true
                        local cluster_infra_id
                        cluster_infra_id=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null)
                        if [[ -n "$cluster_infra_id" ]]; then
                            oc patch machineset.machine.openshift.io "$machineset" -n openshift-machine-api --type=json \
                                -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/providerSpec/value/subnet/filters/0/values/0\",\"value\":\"${cluster_infra_id}-subnet-private-${new_zone}\"}]" 2>/dev/null || true
                        fi
                    elif [[ "$cloud" == "gcp" ]]; then
                        oc patch machineset.machine.openshift.io "$machineset" -n openshift-machine-api --type=merge \
                            -p "{\"spec\":{\"template\":{\"spec\":{\"providerSpec\":{\"value\":{\"zone\":\"${new_zone}\"}}}}}}" 2>/dev/null || true
                    fi
                fi
            elif echo "$failed_machines" | grep -q "fatal"; then
                local fail_msg
                fail_msg=$(echo "$failed_machines" | head -1)
                log_error "Worker failed with non-recoverable error. Check machine status in openshift-machine-api."
                return 1
            fi
        fi

        # Adaptive polling: fast for first 5min, then slow down
        if (( elapsed < 300 )); then
            poll_interval=15
        else
            poll_interval=30
        fi

        sleep "$poll_interval"
        elapsed=$(( elapsed + poll_interval ))
    done
    echo ""
    log_error "Worker provisioning timed out after ${timeout}s"
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
