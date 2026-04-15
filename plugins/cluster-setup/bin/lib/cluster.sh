#!/usr/bin/env bash
# Cluster create/destroy with worker node zone fallback
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/monitor.sh"
source "${SCRIPT_DIR}/install-config.sh"

# Create GCP service account if needed
setup_gcp_service_account() {
    local sa_name="$1"
    local sa_email="${sa_name}@${GCP_PROJECT}.iam.gserviceaccount.com"
    local key_dir="$HOME/.gcp/ocp-dev"
    local key_path="${key_dir}/osServiceAccount.json"

    log_info "Setting up GCP service account: ${sa_email}"

    # Check if SA already exists
    if gcloud iam service-accounts describe "$sa_email" --project="$GCP_PROJECT" &>/dev/null; then
        log_success "Service account already exists: ${sa_email}"
    else
        log_info "Creating service account: ${sa_name}"
        gcloud iam service-accounts create "$sa_name" \
            --display-name="$sa_name" \
            --project="$GCP_PROJECT"
        # Wait for SA to propagate
        sleep 5
    fi

    # Grant required roles (with retry for eventual consistency)
    local roles=(
        compute.admin
        dns.admin
        iam.serviceAccountUser
        iam.securityAdmin
        iam.serviceAccountAdmin
        iam.serviceAccountKeyAdmin
        iam.roleAdmin
        storage.admin
        compute.loadBalancerAdmin
    )
    for role in "${roles[@]}"; do
        local retries=5 wait_time=5
        for ((i=1; i<=retries; i++)); do
            if gcloud projects add-iam-policy-binding "$GCP_PROJECT" \
                --member="serviceAccount:${sa_email}" \
                --role="roles/${role}" \
                --condition=None --quiet &>/dev/null; then
                break
            fi
            if ((i == retries)); then
                log_error "Failed to add role ${role} after ${retries} retries"
                return 1
            fi
            log_warn "Retrying role ${role} in ${wait_time}s... (${i}/${retries})"
            sleep "$wait_time"
            wait_time=$((wait_time * 2))
        done
    done
    log_success "Service account roles granted"

    # Export key if not present
    if [[ ! -f "$key_path" ]]; then
        mkdir -p "$key_dir"
        gcloud iam service-accounts keys create "$key_path" \
            --iam-account="$sa_email" --project="$GCP_PROJECT"
        log_success "Service account key exported to: ${key_path}"
    else
        # Validate existing key is still valid
        if ! gcloud auth activate-service-account --key-file="$key_path" --project="$GCP_PROJECT" &>/dev/null; then
            log_warn "Existing service account key is stale — regenerating"
            rm -f "$key_path"
            gcloud iam service-accounts keys create "$key_path" \
                --iam-account="$sa_email" --project="$GCP_PROJECT"
            log_success "Service account key regenerated: ${key_path}"
        else
            log_success "Service account key already exists: ${key_path}"
        fi
    fi

    export GOOGLE_APPLICATION_CREDENTIALS="$key_path"
}

# Destroy existing cluster
destroy_cluster() {
    local install_dir="$1"

    if [[ -f "${install_dir}/metadata.json" ]]; then
        log_info "Destroying existing cluster..."
        "$OPENSHIFT_INSTALL" destroy cluster --dir="$install_dir" --log-level=info || true
        log_success "Cluster destroyed"
    else
        log_info "No existing cluster found at ${install_dir}"
    fi
}

# Create cluster and monitor worker provisioning
create_cluster() {
    local cloud="$1" cluster_name="$2" gpu="$3" region="$4" worker_zone="$5"
    local pull_secret_path="$6" ssh_key_path="$7" install_dir="$8"
    local instance_type="${9:-}"

    log_phase "Creating OpenShift Cluster"
    if [[ "$gpu" != "none" ]]; then
        log_info "Cloud: ${cloud} | GPU: ${gpu} (${instance_type}) | Region: ${region} | Zone: ${worker_zone}"
    else
        log_info "Cloud: ${cloud} | Instance: ${instance_type} | Region: ${region} | Zone: ${worker_zone}"
    fi
    log_info "Cluster: ${cluster_name}"

    # Setup cloud credentials
    if [[ "$cloud" == "gcp" ]]; then
        setup_gcp_service_account "$cluster_name"
    elif [[ "$cloud" == "aws" ]]; then
        if [[ ! -f "$HOME/.aws/credentials" ]]; then
            log_error "AWS credentials not found at ~/.aws/credentials"
            return 1
        fi
        log_success "AWS credentials found"
    fi

    # If install-config.yaml already exists, use it (user may have edited it)
    if [[ -f "${install_dir}/install-config.yaml" ]]; then
        log_info "Using existing install-config.yaml in ${install_dir}"
        cp "${install_dir}/install-config.yaml" "${install_dir}/install-config.yaml.bak"
    else
        # Clean install dir (openshift-install needs a clean dir)
        rm -rf "${install_dir}"
        mkdir -p "${install_dir}"

        # Generate install-config
        generate_install_config "$cloud" "$cluster_name" "$gpu" "$region" "$worker_zone" \
            "$pull_secret_path" "$ssh_key_path" "$install_dir" "$instance_type"

        # Keep a backup (openshift-install consumes the file)
        cp "${install_dir}/install-config.yaml" "${install_dir}/install-config.yaml.bak"
    fi

    # Destroy any previous cluster with same name
    destroy_cluster "$install_dir"

    # Re-copy install-config after destroy (it may have been consumed)
    if [[ ! -f "${install_dir}/install-config.yaml" ]]; then
        cp "${install_dir}/install-config.yaml.bak" "${install_dir}/install-config.yaml"
    fi

    # Create cluster with parallel worker monitoring
    log_info "Running openshift-install create cluster (this takes 30-45 minutes)..."
    local installer_pid="" monitor_pid=""
    trap 'kill $installer_pid $monitor_pid 2>/dev/null || true; exit 1' INT TERM
    "$OPENSHIFT_INSTALL" create cluster --dir="$install_dir" --log-level=info 2>&1 | tee "${install_dir}/install.log" &
    installer_pid=$!

    # Wait for kubeconfig to appear (bootstrap complete) before starting worker monitoring
    log_info "Waiting for bootstrap to complete (kubeconfig to appear)..."
    local bootstrap_elapsed=0
    while (( bootstrap_elapsed < 2400 )); do  # 40 min max for bootstrap
        if [[ -f "${install_dir}/auth/kubeconfig" ]]; then
            export KUBECONFIG="${install_dir}/auth/kubeconfig"
            log_success "Bootstrap complete. KUBECONFIG available."
            break
        fi
        # Check if installer already exited (early failure)
        if ! kill -0 "$installer_pid" 2>/dev/null; then
            wait "$installer_pid" || true
            if [[ -f "${install_dir}/auth/kubeconfig" ]]; then
                export KUBECONFIG="${install_dir}/auth/kubeconfig"
                break
            fi
            log_error "openshift-install failed before bootstrap completed. Check ${install_dir}/install.log"
            return 1
        fi
        sleep 15
        bootstrap_elapsed=$(( bootstrap_elapsed + 15 ))
    done

    if [[ -z "${KUBECONFIG:-}" ]]; then
        log_error "Bootstrap timed out after 40 minutes. Check ${install_dir}/install.log"
        kill "$installer_pid" 2>/dev/null || true
        return 1
    fi

    # Start worker monitoring in parallel with installer
    # Wait for control plane to be Ready first — on AWS CAPI, infrastructure
    # creation happens after kubeconfig appears so workers don't exist yet.
    # On GCP IPI this resolves almost immediately.
    log_phase "Monitoring Worker Provisioning (parallel with installer)"
    {
        log_info "Waiting for control plane nodes to be Ready..."
        local cp_wait=0
        while ! oc get nodes -l 'node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null | grep -q " Ready" && \
              ! oc get nodes -l 'node-role.kubernetes.io/master' --no-headers 2>/dev/null | grep -q " Ready"; do
            sleep 15
            cp_wait=$(( cp_wait + 15 ))
            if (( cp_wait >= 1200 )); then
                log_error "Control plane did not become Ready within 20 minutes"
                return 1
            fi
        done
        log_success "Control plane is Ready, monitoring worker provisioning"

        if [[ "$gpu" != "none" ]]; then
            monitor_worker_provisioning "$cloud" "$gpu" 1800 "$region"
        else
            wait_for_nodes_ready 1800 1
        fi
    } &
    monitor_pid=$!

    # Wait for installer to finish
    local install_rc=0
    wait "$installer_pid" || install_rc=$?

    if [[ $install_rc -ne 0 && "$gpu" != "none" ]]; then
        # Installer failed but GPU cluster — let monitor continue for zone fallback
        log_warn "Installer exited with rc=${install_rc} — waiting for GPU worker zone fallback..."
        grep -i "level=error" "${install_dir}/install.log" 2>/dev/null | tail -3 || true
    elif [[ $install_rc -ne 0 ]]; then
        # Non-GPU cluster failed — no zone fallback possible
        kill "$monitor_pid" 2>/dev/null || true
        wait "$monitor_pid" 2>/dev/null || true
        log_error "Cluster creation failed (exit code ${install_rc})"
        log_error "Check logs: ${install_dir}/install.log"
        grep -i "level=error" "${install_dir}/install.log" 2>/dev/null | tail -5 || true
        return 1
    fi

    # Wait for monitor to confirm worker is ready
    local monitor_rc=0
    wait "$monitor_pid" || monitor_rc=$?

    if [[ $install_rc -eq 0 ]]; then
        log_success "Cluster created successfully."
    elif [[ $monitor_rc -eq 0 ]]; then
        # Installer reported error but worker is ready (zone fallback may have saved it)
        log_warn "openshift-install exited with rc=${install_rc} but worker is ready."
    else
        log_error "Cluster creation failed. Installer rc=${install_rc}, monitor rc=${monitor_rc}"
        log_error "Check ${install_dir}/install.log"
        return 1
    fi

    # Patch MachineSet for GPU accelerator if needed (GCP T4)
    if [[ "$gpu" != "none" ]] && needs_machineset_gpu_patch "$cloud" "$gpu"; then
        patch_machineset_gpu_accelerator "$cloud" "$gpu" "$region"
    fi

    # Final verification
    log_info "Cluster nodes:"
    oc get nodes
}

# Delete failed worker machines (used by zone fallback and transient retry)
delete_failed_worker_machines() {
    oc get machines.machine.openshift.io -n openshift-machine-api -o name 2>/dev/null \
        | grep worker | while read -r m; do
        local phase
        phase=$(oc get "$m" -n openshift-machine-api -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [[ "$phase" == "Failed" ]]; then
            oc delete "$m" -n openshift-machine-api 2>/dev/null || true
        fi
    done
}

# Patch worker MachineSet to add GPU accelerator
# Required for GCP T4: install-config accelerator field is ignored by the installer
# Includes zone fallback: if machine fails with capacity error, tries next zone
patch_machineset_gpu_accelerator() {
    local cloud="$1" gpu="$2" region="${3:-}"

    log_phase "Patching MachineSet for GPU Accelerator"

    local accelerator_type
    accelerator_type=$(get_gcp_accelerator_type "$gpu")
    if [[ -z "$accelerator_type" ]]; then
        log_info "No accelerator patch needed for ${gpu}"
        return 0
    fi

    # Get the worker MachineSet name
    local machineset
    machineset=$(oc get machinesets.machine.openshift.io -n openshift-machine-api \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "$machineset" ]]; then
        log_error "No worker MachineSet found"
        return 1
    fi

    log_info "Patching MachineSet ${machineset} with accelerator: ${accelerator_type}"

    # Scale down to 0 first — existing machines don't have GPU
    oc scale machineset.machine.openshift.io "$machineset" -n openshift-machine-api --replicas=0
    log_info "Scaled down MachineSet to 0, waiting for machines to terminate..."

    # Wait for old machines to be deleted
    local elapsed=0
    while (( elapsed < 300 )); do
        local count
        count=$(oc get machines.machine.openshift.io -n openshift-machine-api \
                --no-headers 2>/dev/null | grep -c "worker" || true)
        if (( count == 0 )); then
            break
        fi
        sleep 10
        elapsed=$(( elapsed + 10 ))
    done

    # Patch the MachineSet to add GPU accelerator
    if [[ "$cloud" == "gcp" ]]; then
        oc patch machineset.machine.openshift.io "$machineset" -n openshift-machine-api --type=merge -p '{
            "spec": {
                "template": {
                    "spec": {
                        "providerSpec": {
                            "value": {
                                "gpus": [
                                    {
                                        "count": 1,
                                        "type": "'"${accelerator_type}"'"
                                    }
                                ],
                                "onHostMaintenance": "Terminate"
                            }
                        }
                    }
                }
            }
        }'
    fi

    log_success "MachineSet patched with ${accelerator_type}"

    # Scale back up and monitor with zone fallback
    oc scale machineset.machine.openshift.io "$machineset" -n openshift-machine-api --replicas=1
    log_info "Scaled MachineSet back to 1, waiting for GPU worker node..."

    # Get zone fallback list filtered to region
    local zones zone_array current_zone_idx=0
    zones=$(get_zone_priority "$cloud" "$gpu")
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

    # Monitor with zone fallback — try all zones twice before giving up
    # Zone list is doubled: [b, c, d, b, c, d] so we cycle through twice
    local double_zones=("${zone_array[@]}" "${zone_array[@]}")
    elapsed=0
    local timeout=1200
    local poll_interval=15
    while (( elapsed < timeout )); do
        # Check if worker is Ready
        local ready
        ready=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | grep -c " Ready" || true)
        if (( ready > 0 )); then
            log_success "GPU worker node is Ready"
            return 0
        fi

        # Check for failed worker machines
        local failed_phase
        failed_phase=$(oc get machines.machine.openshift.io -n openshift-machine-api \
            -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null \
            | grep worker | grep -o "Failed" | head -1 || true)

        if [[ "$failed_phase" == "Failed" ]]; then
            local fail_msg
            fail_msg=$(oc get machines.machine.openshift.io -n openshift-machine-api -o json 2>/dev/null \
                | python3 -c "
import json, sys
data = json.load(sys.stdin)
for m in data.get('items', []):
    if 'worker' in m['metadata']['name'] and m.get('status',{}).get('phase') == 'Failed':
        for c in m.get('status',{}).get('conditions',[]):
            print(c.get('message',''))
        break
" 2>/dev/null || true)

            # Zone fallback on capacity or instance-not-found errors
            if echo "$fail_msg" | grep -qi -e "capacity" -e "exhausted" -e "ZONE_RESOURCE_POOL" -e "Instance not found" -e "InstanceMissing" -e "can't find created instance"; then
                current_zone_idx=$(( current_zone_idx + 1 ))
                if (( current_zone_idx >= ${#double_zones[@]} )); then
                    log_error "All zones tried twice for ${gpu} GPU in ${region:-all regions}"
                    return 1
                fi
                local new_zone="${double_zones[$current_zone_idx]}"
                log_warn "Worker failed: ${fail_msg}"
                log_warn "Trying zone: ${new_zone} (attempt $(( current_zone_idx + 1 ))/${#double_zones[@]})"

                delete_failed_worker_machines
                oc patch machineset.machine.openshift.io "$machineset" -n openshift-machine-api --type=merge \
                    -p "{\"spec\":{\"template\":{\"spec\":{\"providerSpec\":{\"value\":{\"zone\":\"${new_zone}\"}}}}}}" 2>/dev/null || true
                oc scale machineset.machine.openshift.io "$machineset" -n openshift-machine-api --replicas=1
                log_info "MachineSet patched to zone ${new_zone}, waiting for worker..."
            else
                log_error "Machine failed: ${fail_msg}"
                return 1
            fi
        fi

        sleep "$poll_interval"
        elapsed=$(( elapsed + poll_interval ))
        echo -ne "\r  Elapsed: ${elapsed}s / ${timeout}s"
    done
    echo ""
    log_error "GPU worker node did not become Ready within ${timeout}s"
    return 1
}
