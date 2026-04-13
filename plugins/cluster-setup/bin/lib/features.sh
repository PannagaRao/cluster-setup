#!/usr/bin/env bash
# Enable DRA feature gates on OpenShift cluster
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/monitor.sh"

enable_dra_feature_gates() {
    local mig_mode="${1:-timeslicing}"

    log_phase "Enabling DRA Feature Gates"

    # Add DRAPartitionableDevices only when MIG is needed
    if [[ "$mig_mode" == "dynamicmig" ]]; then
        DRA_FEATURE_GATES+=("DRAPartitionableDevices=true")
        log_info "MIG mode requested — including DRAPartitionableDevices"
    fi

    # Detect the field type for customNoUpgrade.enabled — older OCP uses []object
    # with {"featureGateName": "..."}, while 4.21+ uses []string
    local field_type
    field_type=$(oc explain featuregate.spec.customNoUpgrade.enabled 2>/dev/null | grep -oP '(?<=<\[]).*(?=\])' || echo "string")

    # Build the feature gate patch
    local gates_json="["
    local first=true
    for gate in "${DRA_FEATURE_GATES[@]}"; do
        local name="${gate%=*}"
        if [[ "$first" == "true" ]]; then
            first=false
        else
            gates_json+=","
        fi
        if [[ "$field_type" == "string" ]]; then
            gates_json+="\"${name}\""
        else
            gates_json+="{\"featureGateName\":\"${name}\"}"
        fi
    done
    gates_json+="]"

    log_info "Patching cluster feature gate with: ${DRA_FEATURE_GATES[*]}"

    oc patch featuregate cluster --type=merge --patch "{
        \"spec\": {
            \"featureSet\": \"CustomNoUpgrade\",
            \"customNoUpgrade\": {
                \"enabled\": ${gates_json}
            }
        }
    }"

    log_success "Feature gate patched"

    # Monitor MCP rollout
    log_info "Nodes will restart to apply feature gates. Monitoring MCP rollout..."
    # Give the MCO a moment to start processing
    sleep 30

    wait_for_mcp_rollout 1200

    # Verify worker is still healthy after rollout
    verify_worker_healthy
}
