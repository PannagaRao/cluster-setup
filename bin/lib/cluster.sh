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
        log_success "Service account key already exists: ${key_path}"
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

    log_phase "Creating OpenShift Cluster"
    log_info "Cloud: ${cloud} | GPU: ${gpu} | Region: ${region} | Zone: ${worker_zone}"
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

    # Clean install dir (openshift-install needs a clean dir)
    rm -rf "${install_dir}"
    mkdir -p "${install_dir}"

    # Generate install-config
    generate_install_config "$cloud" "$cluster_name" "$gpu" "$region" "$worker_zone" \
        "$pull_secret_path" "$ssh_key_path" "$install_dir"

    # Keep a backup (openshift-install consumes the file)
    cp "${install_dir}/install-config.yaml" "${install_dir}/install-config.yaml.bak"

    # Destroy any previous cluster with same name
    destroy_cluster "$install_dir"

    # Re-copy install-config after destroy (it may have been consumed)
    if [[ ! -f "${install_dir}/install-config.yaml" ]]; then
        cp "${install_dir}/install-config.yaml.bak" "${install_dir}/install-config.yaml"
    fi

    # Create cluster
    log_info "Running openshift-install create cluster (this takes 30-45 minutes)..."
    "$OPENSHIFT_INSTALL" create cluster --dir="$install_dir" --log-level=info 2>&1 | tee "${install_dir}/install.log" || {
        log_error "openshift-install failed. Check ${install_dir}/install.log"
        return 1
    }

    # Set KUBECONFIG
    export KUBECONFIG="${install_dir}/auth/kubeconfig"
    log_success "Cluster created. KUBECONFIG=${KUBECONFIG}"

    # Monitor worker node provisioning with zone fallback
    log_phase "Monitoring Worker Provisioning"
    monitor_worker_provisioning "$cloud" "$gpu" 1800

    # Patch MachineSet for GPU accelerator if needed (GCP T4)
    if needs_machineset_gpu_patch "$cloud" "$gpu"; then
        patch_machineset_gpu_accelerator "$cloud" "$gpu"
    fi

    # Final verification
    log_info "Cluster nodes:"
    oc get nodes
}

# Patch worker MachineSet to add GPU accelerator
# Required for GCP T4: install-config accelerator field is ignored by the installer
patch_machineset_gpu_accelerator() {
    local cloud="$1" gpu="$2"

    log_phase "Patching MachineSet for GPU Accelerator"

    local accelerator_type
    accelerator_type=$(get_gcp_accelerator_type "$gpu")
    if [[ -z "$accelerator_type" ]]; then
        log_info "No accelerator patch needed for ${gpu}"
        return 0
    fi

    # Get the worker MachineSet name
    local machineset
    machineset=$(oc get machines.machine.openshift.ioets.machine.openshift.io -n openshift-machine-api \
        -l machine.openshift.io/cluster-api-machine-role=worker \
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
            -l machine.openshift.io/cluster-api-machine-role=worker \
            --no-headers 2>/dev/null | wc -l)
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

    # Scale back up
    oc scale machineset.machine.openshift.io "$machineset" -n openshift-machine-api --replicas=1
    log_info "Scaled MachineSet back to 1, waiting for GPU worker node..."

    # Wait for new worker with GPU to be Ready
    wait_for_nodes_ready 1200 1
    log_success "GPU worker node is Ready"
}
