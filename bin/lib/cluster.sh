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

        # Grant required roles
        for role in compute.admin dns.admin iam.serviceAccountUser storage.admin; do
            gcloud projects add-iam-policy-binding "$GCP_PROJECT" \
                --member="serviceAccount:${sa_email}" \
                --role="roles/${role}" --quiet &>/dev/null
        done
        log_success "Service account created with required roles"
    fi

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

    # Final verification
    log_info "Cluster nodes:"
    oc get nodes
}
