#!/usr/bin/env bash
# Health check: show status of all components
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/config.sh"

check_component() {
    local name="$1" check_cmd="$2"
    echo -n "  ${name}: "
    if eval "$check_cmd" &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}MISSING/UNHEALTHY${NC}"
    fi
}

log_phase "Cluster Health Check"

echo "KUBECONFIG: ${KUBECONFIG:-not set}"
echo ""

# Cluster connectivity
echo "Cluster:"
check_component "API Server" "oc cluster-info"
check_component "Worker Nodes" "oc get nodes -l node-role.kubernetes.io/worker --no-headers | grep -q 'Ready'"
echo ""

# Feature Gates
echo "Feature Gates:"
check_component "DRA FeatureGate" "oc get featuregate cluster -o jsonpath='{.spec.featureSet}' | grep -q CustomNoUpgrade"
echo ""

# MCP Status
echo "MachineConfigPools:"
oc get mcp --no-headers 2>/dev/null | while read -r line; do
    name=$(echo "$line" | awk '{print $1}')
    updated=$(echo "$line" | awk '{print $3}')
    degraded=$(echo "$line" | awk '{print $5}')
    if [[ "$degraded" == "True" ]]; then
        echo -e "  ${name}: ${RED}DEGRADED${NC}"
    elif [[ "$updated" == "True" ]]; then
        echo -e "  ${name}: ${GREEN}UPDATED${NC}"
    else
        echo -e "  ${name}: ${YELLOW}UPDATING${NC}"
    fi
done
echo ""

# Components
echo "Components:"
check_component "cert-manager" "oc get pods -n cert-manager --no-headers 2>/dev/null | grep -q Running"
check_component "NFD" "oc get pods -n node-feature-discovery --no-headers 2>/dev/null | grep -q Running"
check_component "GPU Operator" "oc get pods -n nvidia-gpu-operator -l app=nvidia-driver-daemonset --no-headers 2>/dev/null | grep -q Running"
check_component "DRA Driver" "oc get pods -n nvidia-dra-driver-gpu --no-headers 2>/dev/null | grep -q Running"
echo ""

# DRA Resources
echo "DRA Resources:"
check_component "DeviceClass" "oc get deviceclass --no-headers 2>/dev/null | grep -q ."
check_component "ResourceSlice" "oc get resourceslice --no-headers 2>/dev/null | grep -q ."
echo ""

# Show details
echo "DeviceClasses:"
oc get deviceclass 2>/dev/null || echo "  (none)"
echo ""
echo "ResourceSlices:"
oc get resourceslice 2>/dev/null || echo "  (none)"
echo ""

# GPU node labels
echo ""
echo "GPU-labeled Nodes:"
oc get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null || echo "  (none)"
