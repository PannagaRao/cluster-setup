#!/usr/bin/env bash
# Shared configuration: GPU matrix, zone priorities, defaults
set -euo pipefail

# ============================================================
# GPU Instance Matrix
# ============================================================
# Returns instance type for a given cloud+gpu combination
get_instance_type() {
    local cloud="$1" gpu="$2"
    case "${cloud}-${gpu}" in
        gcp-t4)   echo "g2-standard-4" ;;
        gcp-a100) echo "a2-highgpu-1g" ;;
        gcp-h100) echo "a3-highgpu-1g" ;;
        aws-t4)   echo "g4dn.xlarge" ;;
        aws-a100) echo "p4d.24xlarge" ;;
        aws-h100) echo "p5.48xlarge" ;;
        *) echo "ERROR: unsupported cloud-gpu combo: ${cloud}-${gpu}" >&2; return 1 ;;
    esac
}

# Returns vCPU count for the instance type (needed for quota checks)
get_instance_vcpus() {
    local cloud="$1" gpu="$2"
    case "${cloud}-${gpu}" in
        gcp-t4)   echo 4 ;;
        gcp-a100) echo 12 ;;
        gcp-h100) echo 26 ;;  # a3-highgpu-1g
        aws-t4)   echo 4 ;;
        aws-a100) echo 96 ;;
        aws-h100) echo 192 ;;
        *) echo 0 ;;
    esac
}

# Returns GPU count per instance
get_gpu_count() {
    local cloud="$1" gpu="$2"
    case "${cloud}-${gpu}" in
        gcp-t4)   echo 1 ;;
        gcp-a100) echo 1 ;;
        gcp-h100) echo 1 ;;  # a3-highgpu-1g = 1 H100
        aws-t4)   echo 1 ;;
        aws-a100) echo 8 ;;  # p4d.24xlarge = 8 A100
        aws-h100) echo 8 ;;  # p5.48xlarge = 8 H100
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
        *) return 1 ;;
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
    local cloud="$1" gpu="$2"
    case "${cloud}-${gpu}" in
        gcp-t4)   echo "us-central1-a us-central1-b us-central1-c us-east1-b us-east1-c us-east1-d" ;;
        gcp-a100) echo "us-central1-f us-central1-a us-central1-b us-central1-c us-west1-b us-east1-b" ;;
        gcp-h100) echo "us-central1-a us-central1-b us-central1-c europe-west1-b europe-west1-c us-west1-a" ;;
        aws-t4)   echo "ap-south-1a ap-south-1b ap-south-1c us-east-1a us-east-1b us-east-1c" ;;
        aws-a100) echo "ap-south-1a ap-south-1b ap-south-1c us-east-1a us-east-1b us-east-1c" ;;
        aws-h100) echo "ap-south-1a ap-south-1b ap-south-1c us-east-1a us-east-1b us-east-1c" ;;
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
    local cloud="$1" gpu="$2"
    local zones
    zones=$(get_zone_priority "$cloud" "$gpu")
    local first_zone
    first_zone=$(echo "$zones" | awk '{print $1}')
    get_region_from_zone "$cloud" "$first_zone"
}

# Get default worker zone (first in priority list)
get_default_worker_zone() {
    local cloud="$1" gpu="$2"
    get_zone_priority "$cloud" "$gpu" | awk '{print $1}'
}

# ============================================================
# GCP Defaults
# ============================================================
GCP_PROJECT="${GCP_PROJECT:-}"
GCP_BASE_DOMAIN="${GCP_BASE_DOMAIN:-gcp.devcluster.openshift.com}"
GCP_CONTROL_PLANE_TYPE="${GCP_CONTROL_PLANE_TYPE:-n2-standard-4}"
GCP_CONTROL_PLANE_ZONES=("us-central1-a" "us-central1-b" "us-central1-c")

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
TOOLS_DIR="$(cd "${SCRIPT_DIR}/../../bin/tools" 2>/dev/null && pwd || echo "${SCRIPT_DIR}/../tools")"

# Resolve openshift-install binary: user-provided path > bin/tools/ > PATH > download
resolve_openshift_install() {
    local version="${1:-$OCP_VERSION}"

    # 1. User provided explicit path via env var
    if [[ -n "$OPENSHIFT_INSTALL" && -x "$OPENSHIFT_INSTALL" ]]; then
        log_success "Using openshift-install from OPENSHIFT_INSTALL=${OPENSHIFT_INSTALL}"
        return 0
    fi

    # 2. Check bin/tools/ in the repo
    if [[ -x "${TOOLS_DIR}/openshift-install" ]]; then
        OPENSHIFT_INSTALL="${TOOLS_DIR}/openshift-install"
        log_success "Using openshift-install from ${TOOLS_DIR}/"
        return 0
    fi

    # 3. Check PATH
    if command -v openshift-install &>/dev/null; then
        OPENSHIFT_INSTALL="$(command -v openshift-install)"
        log_success "Using openshift-install from PATH: ${OPENSHIFT_INSTALL}"
        return 0
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

    url="https://mirror.openshift.com/pub/openshift-v4/${arch}/clients/ocp/${version}/openshift-install-${platform}.tar.gz"

    mkdir -p "$TOOLS_DIR"
    local tarball="${TOOLS_DIR}/openshift-install-${version}.tar.gz"

    log_info "Downloading from: ${url}"
    if ! curl -fSL -o "$tarball" "$url"; then
        log_error "Failed to download openshift-install ${version}"
        log_error "URL: ${url}"
        log_error "Set OPENSHIFT_INSTALL=/path/to/openshift-install or place it in bin/tools/"
        return 1
    fi

    tar -xzf "$tarball" -C "$TOOLS_DIR" openshift-install
    rm -f "$tarball"
    chmod +x "${TOOLS_DIR}/openshift-install"
    OPENSHIFT_INSTALL="${TOOLS_DIR}/openshift-install"
    log_success "Downloaded openshift-install ${version} to ${TOOLS_DIR}/"
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
