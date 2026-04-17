#!/usr/bin/env bash
# Install cert-manager operator
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/monitor.sh"

install_cert_manager() {
    log_phase "Installing cert-manager"

    # Create namespace
    oc create namespace cert-manager 2>/dev/null || true

    # Check if cert-manager is in redhat-operators (4.21) or needs community-operators (4.22+)
    local source="redhat-operators"
    local pkg_name="openshift-cert-manager-operator"
    local channel
    local target_ns="openshift-operators"

    if oc get packagemanifest "$pkg_name" -n openshift-marketplace &>/dev/null; then
        channel=$(oc get packagemanifest "$pkg_name" -n openshift-marketplace \
            -o jsonpath='{.status.defaultChannel}' 2>/dev/null) || channel="stable-v1"
    else
        # Not in redhat-operators — use community-operators (OCP 4.22+)
        log_warn "cert-manager not found in redhat-operators, using community-operators"
        source="community-operators"
        pkg_name="cert-manager"
        channel="stable"
        target_ns="cert-manager"

        # community-operators needs an OperatorGroup in the target namespace
        cat <<OGEOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager
  namespace: cert-manager
OGEOF
    fi

    log_info "Using cert-manager: source=${source}, channel=${channel}"

    # Install via OLM subscription
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cert-manager
  namespace: ${target_ns}
spec:
  channel: ${channel}
  name: ${pkg_name}
  source: ${source}
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

    log_info "cert-manager subscription created. Waiting for operator pods..."

    # Wait for cert-manager pods to be Running
    # The operator deploys into cert-manager namespace
    wait_for_pods_running "cert-manager" "app.kubernetes.io/instance=cert-manager" 600

    # Verify cert-manager is functional by checking webhook
    wait_for "cert-manager webhook ready" 120 10 \
        oc get deployment cert-manager-webhook -n cert-manager -o jsonpath='{.status.readyReplicas}' 2>/dev/null

    log_success "cert-manager installed and ready"
}
