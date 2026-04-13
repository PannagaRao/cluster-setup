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

    # Auto-detect the default channel from the package manifest
    local channel
    channel=$(oc get packagemanifest openshift-cert-manager-operator -n openshift-marketplace \
        -o jsonpath='{.status.defaultChannel}' 2>/dev/null) || channel="stable-v1"
    log_info "Using cert-manager channel: ${channel}"

    # Install via OLM subscription
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cert-manager
  namespace: openshift-operators
spec:
  channel: ${channel}
  name: openshift-cert-manager-operator
  source: redhat-operators
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
