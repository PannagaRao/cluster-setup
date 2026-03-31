#!/usr/bin/env bash
# Install Node Feature Discovery and label GPU nodes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/monitor.sh"

install_nfd() {
    log_phase "Installing Node Feature Discovery"

    local namespace="node-feature-discovery"

    # Create namespace
    oc create namespace "$namespace" 2>/dev/null || true

    # Grant SCC
    for sa in node-feature-discovery node-feature-discovery-worker node-feature-discovery-gc; do
        oc adm policy add-scc-to-user privileged -n "$namespace" -z "$sa" 2>/dev/null || true
    done

    # Add helm repo
    helm repo add nfd https://kubernetes-sigs.github.io/node-feature-discovery/charts 2>/dev/null || true
    helm repo update nfd 2>/dev/null || true

    # Install or upgrade
    helm upgrade --install node-feature-discovery nfd/node-feature-discovery \
        --namespace "$namespace" \
        --version "$NFD_CHART_VERSION" \
        --set "master.serviceAccount.name=node-feature-discovery" \
        --set "worker.serviceAccount.name=node-feature-discovery-worker" \
        --wait --timeout 5m

    log_success "NFD helm chart installed"

    # Wait for NFD pods
    wait_for_pods_running "$namespace" "app.kubernetes.io/name=node-feature-discovery" 300

    # Manual GPU labeling as backup (NFD auto-detection can be slow on fresh clusters)
    log_info "Applying manual GPU node labels as backup..."
    local worker_nodes
    worker_nodes=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers -o custom-columns=":metadata.name" 2>/dev/null)

    for node in $worker_nodes; do
        # Get RHCOS OSTREE_VERSION — required by GPU operator to match DTK image
        local rhcos_version
        rhcos_version=$(oc debug "node/${node}" -- chroot /host cat /etc/os-release 2>/dev/null \
            | grep OSTREE_VERSION | cut -d= -f2 | tr -d "'\"") || true

        oc label node "$node" \
            "feature.node.kubernetes.io/pci-10de.present=true" \
            "nvidia.com/gpu.present=true" \
            --overwrite 2>/dev/null || true

        if [[ -n "$rhcos_version" ]]; then
            oc label node "$node" \
                "feature.node.kubernetes.io/system-os_release.OSTREE_VERSION=${rhcos_version}" \
                --overwrite 2>/dev/null || true
            log_success "Labeled node: ${node} (OSTREE_VERSION=${rhcos_version})"
        else
            log_warn "Could not detect OSTREE_VERSION on ${node}"
            log_success "Labeled node: ${node}"
        fi
    done

    # Verify labels
    local labeled
    labeled=$(oc get nodes -l "nvidia.com/gpu.present=true" --no-headers 2>/dev/null | wc -l)
    if (( labeled == 0 )); then
        log_warn "No nodes labeled with nvidia.com/gpu.present=true"
    else
        log_success "GPU-labeled nodes: ${labeled}"
    fi
}
