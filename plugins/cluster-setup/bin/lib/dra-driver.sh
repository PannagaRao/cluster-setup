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
        values_file="${TEMPLATE_DIR}/helm-values-default.yaml"
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

    # A100 GPUs on cloud VMs do not support GPU reset (nvidia-smi --gpu-reset
    # returns "Not Supported"). The DRA driver's DestroyUnknownMIGDevices
    # startup code calls SetMigMode(DISABLE) on every restart, which puts
    # the GPU into a pending-disable state that requires a reboot to resolve.
    # This creates an unrecoverable loop. Use the patched image that skips
    # DestroyUnknownMIGDevices on A100 cloud VMs.
    # H100 supports GPU reset, so the standard image works fine.
    local cloud="${3:-}"
    if [[ "$mig_mode" == "dynamicmig" && "$gpu" == "a100" && -n "$cloud" && ("$cloud" == "gcp" || "$cloud" == "aws") ]]; then
        log_info "A100 on cloud VM detected: using patched DRA driver image (skips DestroyUnknownMIGDevices)"
        set_overrides="${set_overrides} --set image.repository=quay.io/rh-pbhojara/nvidia-driver --set image.tag=v25.12.0-dev-patched --set image.pullPolicy=Always"
    fi

    # Install DRA driver
    # shellcheck disable=SC2086
    helm install nvidia-dra-driver-gpu nvidia/nvidia-dra-driver-gpu \
        --namespace "$namespace" \
        --version "$DRA_DRIVER_CHART_VERSION" \
        -f "$values_file" \
        $set_overrides

    log_success "DRA driver helm chart installed (mode: ${mig_mode})"

    # Wait for DRA driver pods
    wait_for_pods_running "$namespace" "app.kubernetes.io/name=nvidia-dra-driver-gpu" 1200

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

    # A100 on cloud VMs: enable MIG mode, reboot worker, deploy keepalive
    local cloud="${3:-}"
    if [[ "$mig_mode" == "dynamicmig" && "$gpu" == "a100" && -n "$cloud" && ("$cloud" == "gcp" || "$cloud" == "aws") ]]; then
        activate_mig_cloud_vm
    fi
}

# Activate MIG mode on A100 cloud VMs where GPU reset is not supported.
# Steps: enable MIG (pending), reboot worker to apply, deploy keepalive pod.
activate_mig_cloud_vm() {
    log_phase "Activating MIG Mode (A100 Cloud VM)"

    # Find the GPU operator driver daemonset pod
    local driver_pod
    driver_pod=$(oc get pods -n nvidia-gpu-operator --no-headers 2>/dev/null \
        | grep "nvidia-driver-daemonset" | awk '{print $1}' | head -1 || true)

    if [[ -z "$driver_pod" ]]; then
        log_error "No nvidia-driver-daemonset pod found in nvidia-gpu-operator namespace"
        return 1
    fi

    # Check current MIG mode
    local mig_status
    mig_status=$(oc exec -n nvidia-gpu-operator "$driver_pod" -- \
        nvidia-smi --query-gpu=mig.mode.current,mig.mode.pending --format=csv,noheader 2>/dev/null)
    log_info "Current MIG status: ${mig_status}"

    local mig_current mig_pending
    mig_current=$(echo "$mig_status" | awk -F', ' '{print $1}')
    mig_pending=$(echo "$mig_status" | awk -F', ' '{print $2}')

    if [[ "$mig_current" == "Enabled" && "$mig_pending" == "Enabled" ]]; then
        log_success "MIG mode already Enabled/Enabled — skipping reboot"
    else
        # Enable MIG mode (sets pending)
        log_info "Enabling MIG mode on GPU 0..."
        oc exec -n nvidia-gpu-operator "$driver_pod" -- nvidia-smi -i 0 -mig 1 2>&1 || true

        # Reboot worker to apply pending MIG mode change
        local worker
        worker=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}')
        log_info "Rebooting worker ${worker} to activate MIG mode..."

        oc adm cordon "$worker"
        oc adm drain "$worker" --ignore-daemonsets --delete-emptydir-data --force --timeout=120s 2>/dev/null || true
        oc debug "node/${worker}" -- chroot /host shutdown -r now 2>/dev/null || true

        # Wait for node to go NotReady (confirms reboot started)
        log_info "Waiting for worker to begin reboot..."
        local elapsed=0
        while (( elapsed < 120 )); do
            local ready
            ready=$(oc get node "$worker" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
            if [[ "$ready" != "True" ]]; then
                log_info "Worker is rebooting (status: ${ready})"
                break
            fi
            sleep 10
            elapsed=$(( elapsed + 10 ))
        done

        # If we never saw NotReady, the reboot may not have started
        if (( elapsed >= 120 )); then
            log_error "Node did not enter NotReady state within 120s — reboot may have failed"
            return 1
        fi

        # Wait for node to come back Ready
        log_info "Waiting for worker to come back Ready..."
        elapsed=0
        while (( elapsed < 600 )); do
            local ready
            ready=$(oc get node "$worker" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
            if [[ "$ready" == "True" ]]; then
                log_success "Worker is Ready"
                break
            fi
            sleep 15
            elapsed=$(( elapsed + 15 ))
        done

        # Verify node is actually Ready before uncordoning
        local final_ready
        final_ready=$(oc get node "$worker" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [[ "$final_ready" != "True" ]]; then
            log_error "Worker did not become Ready after 600s (status: ${final_ready})"
            return 1
        fi

        oc adm uncordon "$worker"

        # Wait for driver pod to be ready after reboot.
        # Old pods may still show Running briefly — wait for a pod with
        # a recent start time by checking container restart count or age.
        log_info "Waiting for GPU driver pod to restart..."
        local new_driver_pod=""
        elapsed=0
        while (( elapsed < 900 )); do
            new_driver_pod=$(oc get pods -n nvidia-gpu-operator --no-headers 2>/dev/null \
                | grep "nvidia-driver-daemonset" | grep -E "2/2\s+Running" | awk '{print $1}' | head -1 || true)
            if [[ -n "$new_driver_pod" ]]; then
                # Verify we can actually exec into it (confirms it's not a stale pod)
                if oc exec -n nvidia-gpu-operator "$new_driver_pod" -- nvidia-smi --query-gpu=name --format=csv,noheader &>/dev/null; then
                    break
                fi
                new_driver_pod=""
            fi
            sleep 15
            elapsed=$(( elapsed + 15 ))
        done

        if [[ -z "$new_driver_pod" ]]; then
            log_error "Driver pod did not become ready after reboot (waited 900s)"
            return 1
        fi

        # Verify MIG is Enabled/Enabled
        mig_status=$(oc exec -n nvidia-gpu-operator "$new_driver_pod" -- \
            nvidia-smi --query-gpu=mig.mode.current,mig.mode.pending --format=csv,noheader 2>/dev/null)
        log_info "MIG status after reboot: ${mig_status}"

        if [[ "$mig_status" != *"Enabled"*"Enabled"* ]]; then
            log_error "MIG mode is not Enabled/Enabled after reboot: ${mig_status}"
            return 1
        fi
        log_success "MIG mode activated (Enabled/Enabled)"
    fi

    # Deploy keepalive pod to prevent maybeDisableMigMode from triggering
    # when all user MIG devices are deleted
    log_info "Deploying MIG keepalive pod (1g.5gb)..."
    oc create namespace pd-test 2>/dev/null || true

    oc apply -f - <<'KEEPALIVE_EOF'
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  name: keepalive-gpu0
  namespace: pd-test
spec:
  devices:
    requests:
    - name: keepalive
      exactly:
        deviceClassName: mig.nvidia.com
        selectors:
        - cel:
            expression: "device.attributes['gpu.nvidia.com'].profile == '1g.5gb'"
---
apiVersion: v1
kind: Pod
metadata:
  name: keepalive-gpu0
  namespace: pd-test
spec:
  containers:
  - name: keepalive
    image: ubuntu:22.04
    command: ["bash", "-c"]
    args: ["trap 'exit 0' TERM; sleep infinity & wait"]
    resources:
      claims:
      - name: mig-claim
  resourceClaims:
  - name: mig-claim
    resourceClaimName: keepalive-gpu0
  restartPolicy: Always
KEEPALIVE_EOF

    # Wait for keepalive pod
    oc wait --for=condition=Ready pod/keepalive-gpu0 -n pd-test --timeout=120s 2>/dev/null || true
    log_success "MIG keepalive pod deployed"
}
