#!/usr/bin/env bash
# Shared configuration: GPU matrix, zone priorities, defaults
set -euo pipefail

# ============================================================
# GPU Instance Matrix
# ============================================================
# Returns instance type for a given cloud+gpu combination
# Note: GCP T4 uses n1-standard-4 base + accelerator (not a dedicated GPU instance)
get_instance_type() {
    local cloud="$1" gpu="$2"
    case "${cloud}-${gpu}" in
        gcp-t4)   echo "n1-standard-8" ;;  # T4 attached as accelerator post-install; 8 vCPUs for faster driver compilation
        gcp-l4)   echo "g2-standard-8" ;;  # L4 is built into g2 instance; 8 vCPUs for faster driver compilation
        gcp-a100) echo "a2-highgpu-1g" ;;
        gcp-h100) echo "a3-highgpu-1g" ;;
        aws-t4)   echo "g4dn.xlarge" ;;
        aws-a100) echo "p4d.24xlarge" ;;
        aws-h100) echo "p5.4xlarge" ;;   # 1 H100 with MIG support
        gcp-none) echo "n2-standard-4" ;;   # default non-GPU instance
        aws-none) echo "m6i.xlarge" ;;     # default non-GPU instance
        *) echo "ERROR: unsupported cloud-gpu combo: ${cloud}-${gpu}" >&2; return 1 ;;
    esac
}

# Detect GPU type from instance type string (reverse of get_instance_type)
# Returns: t4, l4, a100, h100, maybe-t4, or none
# "maybe-t4" means GCP n1-* which CAN have a T4 accelerator attached but doesn't by default
detect_gpu_from_instance_type() {
    local cloud="$1" instance_type="$2"
    case "$cloud" in
        aws)
            case "$instance_type" in
                g4dn.*) echo "t4" ;;
                p4d.*)  echo "a100" ;;
                p5.*)   echo "h100" ;;
                *)      echo "none" ;;
            esac
            ;;
        gcp)
            case "$instance_type" in
                g2-*)  echo "l4" ;;
                a2-*)  echo "a100" ;;
                a3-*)  echo "h100" ;;
                n1-*)  echo "maybe-t4" ;;  # T4 is optional accelerator add-on
                *)     echo "none" ;;
            esac
            ;;
        *) echo "none" ;;
    esac
}

# Returns GCP accelerator type for GPU (empty if GPU is built into instance type)
get_gcp_accelerator_type() {
    local gpu="$1"
    case "$gpu" in
        t4) echo "nvidia-tesla-t4" ;;
        *)  echo "" ;;  # l4/a100/h100 are dedicated GPU instance types, no accelerator needed
    esac
}

# Returns true if this cloud+gpu combo needs post-install MachineSet patching for GPU
needs_machineset_gpu_patch() {
    local cloud="$1" gpu="$2"
    # GCP T4: accelerator field in install-config is ignored, must patch MachineSet
    [[ "$cloud" == "gcp" && "$gpu" == "t4" ]]
}

# Returns vCPU count for the instance type (needed for quota checks)
get_instance_vcpus() {
    local cloud="$1" gpu="$2"
    case "${cloud}-${gpu}" in
        gcp-t4)   echo 8 ;;

        gcp-l4)   echo 8 ;;  # g2-standard-8
        gcp-a100) echo 12 ;;
        gcp-h100) echo 26 ;;  # a3-highgpu-1g
        aws-t4)   echo 4 ;;
        aws-a100) echo 96 ;;
        aws-h100) echo 16 ;;   # p5.4xlarge
        *) echo 0 ;;
    esac
}

# Returns GPU count per instance
get_gpu_count() {
    local cloud="$1" gpu="$2"
    case "${cloud}-${gpu}" in
        gcp-t4)   echo 1 ;;
        gcp-l4)   echo 1 ;;
        gcp-a100) echo 1 ;;
        gcp-h100) echo 1 ;;  # a3-highgpu-1g = 1 H100
        aws-t4)   echo 1 ;;
        aws-a100) echo 8 ;;  # p4d.24xlarge = 8 A100
        aws-h100) echo 1 ;;  # p5.4xlarge = 1 H100
        *) echo 0 ;;
    esac
}

# ============================================================
# MIG Capability
# ============================================================
gpu_supports_mig() {
    local gpu="$1"
    case "$gpu" in
        a100|h100) return 0 ;;
        *)         return 1 ;;  # t4, l4 do not support MIG
    esac
}

# Returns DRA driver MIG flag based on GPU type and user preference
get_mig_mode() {
    local gpu="$1" requested_mode="${2:-timeslicing}"
    if ! gpu_supports_mig "$gpu"; then
        if [[ "$requested_mode" == "dynamicmig" ]]; then
            echo "WARNING: $gpu does not support MIG. Falling back to timeslicing." >&2
        fi
        echo "timeslicing"
    else
        echo "$requested_mode"
    fi
}

# ============================================================
# Zone Priorities (fallback order on stockout)
# ============================================================
get_zone_priority() {
    local cloud="$1" gpu="${2:-none}"
    case "${cloud}-${gpu}" in
        gcp-t4)   echo "us-east1-b us-east1-c us-east1-d us-central1-a us-central1-b us-central1-c" ;;
        gcp-l4)   echo "us-east1-b us-east1-c us-east1-d us-central1-a us-central1-b us-central1-c us-west1-a us-west1-b us-west1-c" ;;
        gcp-a100) echo "us-central1-f us-central1-a us-central1-b us-central1-c us-east1-b us-east1-c us-east1-d" ;;
        gcp-h100) echo "us-east1-b us-east1-c us-east1-d us-central1-a us-central1-b us-central1-c" ;;
        gcp-none) echo "us-east1-b us-east1-c us-east1-d" ;;
        aws-t4)   echo "ap-south-1a ap-south-1b ap-south-1c us-east-1a us-east-1b us-east-1c" ;;
        aws-a100) echo "ap-south-1a ap-south-1b ap-south-1c us-east-1a us-east-1b us-east-1c" ;;
        aws-h100) echo "ap-south-1a ap-south-1b ap-south-1c us-east-1a us-east-1b us-east-1c" ;;
        aws-none) echo "us-east-1a us-east-1b us-east-1c" ;;
        *) echo "" ;;
    esac
}

# Extract region from zone
get_region_from_zone() {
    local cloud="$1" zone="$2"
    case "$cloud" in
        gcp) echo "${zone%-*}" ;;       # us-central1-a -> us-central1
        aws) echo "${zone%[a-f]}" ;;     # us-east-1a -> us-east-1
        *) echo "$zone" ;;
    esac
}

# Get default region for a cloud+gpu combo
get_default_region() {
    local cloud="$1" gpu="${2:-none}"
    local zones
    zones=$(get_zone_priority "$cloud" "$gpu")
    local first_zone
    first_zone=$(echo "$zones" | awk '{print $1}')
    get_region_from_zone "$cloud" "$first_zone"
}

# Get default worker zone (first in priority list)
get_default_worker_zone() {
    local cloud="$1" gpu="${2:-none}"
    get_zone_priority "$cloud" "$gpu" | awk '{print $1}'
}

# ============================================================
# GCP Defaults
# ============================================================
GCP_PROJECT="${GCP_PROJECT:-}"
GCP_BASE_DOMAIN="${GCP_BASE_DOMAIN:-gcp.devcluster.openshift.com}"
GCP_CONTROL_PLANE_TYPE="${GCP_CONTROL_PLANE_TYPE:-n2-standard-4}"
# NOTE: GCP control plane zones are resolved dynamically from the chosen region
# in install-config.sh via: gcloud compute zones list --filter="region=${region}"

# ============================================================
# AWS Defaults
# ============================================================
AWS_BASE_DOMAIN="${AWS_BASE_DOMAIN:-devcluster.openshift.com}"
AWS_CONTROL_PLANE_TYPE="${AWS_CONTROL_PLANE_TYPE:-m6i.xlarge}"

# ============================================================
# OpenShift
# ============================================================
OCP_VERSION="${OCP_VERSION:-4.21.0}"
OPENSHIFT_INSTALL="${OPENSHIFT_INSTALL:-}"
# PLUGIN_ROOT: two levels up from bin/lib/ — works both locally and as installed plugin
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOOLS_DIR="${HOME}/.local/share/cluster-setup/tools"

# Resolve openshift-install binary: user-provided path > bin/tools/ > PATH > download
resolve_openshift_install() {
    local version="${1:-$OCP_VERSION}"

    # 1. User provided explicit path via env var
    if [[ -n "$OPENSHIFT_INSTALL" && -x "$OPENSHIFT_INSTALL" ]]; then
        log_success "Using openshift-install from OPENSHIFT_INSTALL=${OPENSHIFT_INSTALL}"
        return 0
    fi

    # 2. Check tools dir — verify version matches
    if [[ -x "${TOOLS_DIR}/openshift-install" ]]; then
        local cached_version
        cached_version=$("${TOOLS_DIR}/openshift-install" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
        if [[ "$cached_version" == "$version" || "$cached_version" == "${version%.*}."* ]]; then
            OPENSHIFT_INSTALL="${TOOLS_DIR}/openshift-install"
            log_success "Using openshift-install ${cached_version} from ${TOOLS_DIR}/"
            return 0
        else
            log_warn "Cached openshift-install is ${cached_version}, need ${version} — downloading correct version"
        fi
    fi

    # 3. Check PATH — verify version matches
    if command -v openshift-install &>/dev/null; then
        local path_version
        path_version=$(openshift-install version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
        if [[ "$path_version" == "$version" || "$path_version" == "${version%.*}."* ]]; then
            OPENSHIFT_INSTALL="$(command -v openshift-install)"
            log_success "Using openshift-install ${path_version} from PATH: ${OPENSHIFT_INSTALL}"
            return 0
        fi
    fi

    # 4. Download it
    log_info "openshift-install not found. Downloading version ${version}..."
    download_openshift_install "$version"
}

download_openshift_install() {
    local version="$1"
    local platform arch url

    platform="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
    esac

    mkdir -p "$TOOLS_DIR"
    local tarball="${TOOLS_DIR}/openshift-install-${version}.tar.gz"

    # Try stable/GA release first
    url="https://mirror.openshift.com/pub/openshift-v4/${arch}/clients/ocp/${version}/openshift-install-${platform}.tar.gz"
    log_info "Trying stable release: ${url}"
    if curl -fSL -o "$tarball" "$url" 2>/dev/null; then
        tar -xzf "$tarball" -C "$TOOLS_DIR" openshift-install
        rm -f "$tarball"
        chmod +x "${TOOLS_DIR}/openshift-install"
        OPENSHIFT_INSTALL="${TOOLS_DIR}/openshift-install"
        log_success "Downloaded openshift-install ${version} (stable) to ${TOOLS_DIR}/"
        return 0
    fi

    # Stable not available — try nightly
    log_warn "OCP ${version} is not available as a stable release. Trying nightly..."
    log_warn "Nightly builds require registry.ci.openshift.org auth in your pull secret."
    log_warn "If not present, add it from https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/"

    # Extract major.minor (e.g. 4.22 from 4.22.0, 4.22.0-ec.5, etc.)
    local minor_version
    [[ "$version" =~ ^([0-9]+\.[0-9]+) ]] && minor_version="${BASH_REMATCH[1]}"
    url="https://mirror.openshift.com/pub/openshift-v4/${arch}/clients/ocp-dev-preview/candidate-${minor_version}/openshift-install-${platform}.tar.gz"
    log_info "Trying nightly: ${url}"
    if curl -fSL -o "$tarball" "$url" 2>/dev/null; then
        tar -xzf "$tarball" -C "$TOOLS_DIR" openshift-install
        rm -f "$tarball"
        chmod +x "${TOOLS_DIR}/openshift-install"
        OPENSHIFT_INSTALL="${TOOLS_DIR}/openshift-install"
        log_success "Downloaded openshift-install ${minor_version} (nightly) to ${TOOLS_DIR}/"
        return 0
    fi

    log_error "Failed to download openshift-install ${version} (tried stable and nightly)"
    log_error "Set OPENSHIFT_INSTALL=/path/to/openshift-install or place it in ${TOOLS_DIR}/"
    return 1
}

# ============================================================
# Helm Chart Versions
# ============================================================
NFD_CHART_VERSION="${NFD_CHART_VERSION:-0.17.3}"
GPU_OPERATOR_CHART_VERSION="${GPU_OPERATOR_CHART_VERSION:-v25.10.1}"
DRA_DRIVER_CHART_VERSION="${DRA_DRIVER_CHART_VERSION:-25.12.0}"

# ============================================================
# DRA Feature Gates (applied to OCP cluster)
# ============================================================
# Base gates — always enabled for DRA
DRA_FEATURE_GATES=(
    "DynamicResourceAllocation=true"
    "DRAResourceClaimDeviceStatus=true"
    "DRAExtendedResource=true"
)
# DRAPartitionableDevices is added conditionally by features.sh when MIG mode is dynamicmig

# ============================================================
# Colors and logging
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_phase()   { echo -e "\n${GREEN}========================================${NC}"; echo -e "${GREEN} $*${NC}"; echo -e "${GREEN}========================================${NC}\n"; }

# ============================================================
# GPU Availability Checks
# ============================================================
# Check if instance type is available in any zone in the region (quiet mode)
check_aws_available_quiet() {
    local instance_type="$1" region="$2"

    local zones
    zones=$(aws ec2 describe-availability-zones --region "$region" --query 'AvailabilityZones[*].ZoneName' --output text 2>/dev/null) || return 1

    for zone in $zones; do
        aws ec2 describe-instance-type-offerings \
            --region "$region" \
            --location-type "availability-zone" \
            --filters "Name=location,Values=$zone" "Name=instance-type,Values=$instance_type" \
            --query 'InstanceTypeOfferings[0].InstanceType' \
            --output text 2>/dev/null | grep -q "$instance_type" && return 0
    done

    return 1
}
