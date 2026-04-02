#!/usr/bin/env bash
# Generate install-config.yaml from parameters
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

TEMPLATE_DIR="$(cd "${SCRIPT_DIR}/../../templates" && pwd)"

# Generate install-config.yaml for GCP
generate_gcp_install_config() {
    local cluster_name="$1" gpu="$2" region="$3" worker_zone="$4"
    local pull_secret_path="$5" ssh_key_path="$6" output_dir="$7"

    if [[ -z "$GCP_PROJECT" ]]; then
        log_error "GCP_PROJECT environment variable must be set for GCP clusters"
        return 1
    fi

    local instance_type
    instance_type=$(get_instance_type gcp "$gpu")

    local ssh_key
    ssh_key=$(cat "$ssh_key_path")

    local pull_secret_raw
    pull_secret_raw=$(cat "$pull_secret_path")

    # Determine pull secret line: if file already contains 'pullSecret:' key (e.g. .txt format),
    # use it as-is; otherwise wrap the raw JSON with the YAML key
    local pull_secret_line
    if [[ "$pull_secret_raw" == pullSecret:* ]]; then
        pull_secret_line="${pull_secret_raw}"
    else
        pull_secret_line="pullSecret: '${pull_secret_raw}'"
    fi

    # Determine disk size based on GPU type
    local disk_size=128
    case "$gpu" in
        a100|h100) disk_size=256 ;;
    esac

    # Control plane zones — pick 3 zones in the same region
    local cp_zones
    cp_zones=$(gcloud compute zones list --filter="region=${region}" --format="value(name)" 2>/dev/null | head -3 | paste -sd' ')
    read -ra cp_zone_array <<< "$cp_zones"

    # GPU instances require onHostMaintenance: Terminate
    local on_host_maintenance=""
    case "$gpu" in
        t4|a100|h100) on_host_maintenance="Terminate" ;;
    esac

    cat > "${output_dir}/install-config.yaml" <<EOF
apiVersion: v1
metadata:
  name: ${cluster_name}
baseDomain: ${GCP_BASE_DOMAIN}
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform:
    gcp:
      type: ${instance_type}
${on_host_maintenance:+      onHostMaintenance: ${on_host_maintenance}}
      zones:
      - ${worker_zone}
      osDisk:
        diskSizeGB: ${disk_size}
        diskType: pd-ssd
  replicas: 1
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform:
    gcp:
      type: ${GCP_CONTROL_PLANE_TYPE}
      zones:
$(for z in "${cp_zone_array[@]}"; do echo "      - ${z}"; done)
  replicas: 3
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  gcp:
    projectID: ${GCP_PROJECT}
    region: ${region}
publish: External
${pull_secret_line}
sshKey: '${ssh_key}'
EOF

    log_success "Generated install-config.yaml for GCP (${instance_type} in ${worker_zone})"
}

# Generate install-config.yaml for AWS
generate_aws_install_config() {
    local cluster_name="$1" gpu="$2" region="$3" worker_zone="$4"
    local pull_secret_path="$5" ssh_key_path="$6" output_dir="$7"

    local instance_type
    instance_type=$(get_instance_type aws "$gpu")

    local ssh_key
    ssh_key=$(cat "$ssh_key_path")

    local pull_secret_raw
    pull_secret_raw=$(cat "$pull_secret_path")

    # Determine pull secret line: if file already contains 'pullSecret:' key (e.g. .txt format),
    # use it as-is; otherwise wrap the raw JSON with the YAML key
    local pull_secret_line
    if [[ "$pull_secret_raw" == pullSecret:* ]]; then
        pull_secret_line="${pull_secret_raw}"
    else
        pull_secret_line="pullSecret: '${pull_secret_raw}'"
    fi

    local disk_size=128
    case "$gpu" in
        a100|h100) disk_size=256 ;;
    esac

    cat > "${output_dir}/install-config.yaml" <<EOF
apiVersion: v1
metadata:
  name: ${cluster_name}
baseDomain: ${AWS_BASE_DOMAIN}
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform:
    aws:
      type: ${instance_type}
      zones:
      - ${worker_zone}
      rootVolume:
        size: ${disk_size}
        type: gp3
  replicas: 1
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform:
    aws:
      type: ${AWS_CONTROL_PLANE_TYPE}
  replicas: 3
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: 10.0.0.0/16
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
platform:
  aws:
    region: ${region}
publish: External
${pull_secret_line}
sshKey: '${ssh_key}'
EOF

    log_success "Generated install-config.yaml for AWS (${instance_type} in ${worker_zone})"
}

# Main dispatcher
generate_install_config() {
    local cloud="$1" cluster_name="$2" gpu="$3" region="$4" worker_zone="$5"
    local pull_secret_path="$6" ssh_key_path="$7" output_dir="$8"

    log_phase "Generating install-config.yaml"

    # Validate inputs
    if [[ ! -f "$pull_secret_path" ]]; then
        log_error "Pull secret not found: ${pull_secret_path}"
        return 1
    fi
    if [[ ! -f "$ssh_key_path" ]]; then
        log_error "SSH public key not found: ${ssh_key_path}"
        return 1
    fi

    mkdir -p "$output_dir"

    case "$cloud" in
        gcp) generate_gcp_install_config "$cluster_name" "$gpu" "$region" "$worker_zone" "$pull_secret_path" "$ssh_key_path" "$output_dir" ;;
        aws) generate_aws_install_config "$cluster_name" "$gpu" "$region" "$worker_zone" "$pull_secret_path" "$ssh_key_path" "$output_dir" ;;
        *) log_error "Unknown cloud: $cloud"; return 1 ;;
    esac
}
