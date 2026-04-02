#!/usr/bin/env bash
# Pre-flight quota checks for GCP and AWS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

# Check GCP quota for a given region and GPU type
check_gcp_quota() {
    local gpu="$1" region="$2"

    log_info "Checking GCP quotas in ${region} for ${gpu}..."

    local quota_json
    quota_json=$(gcloud compute regions describe "$region" --format="json" 2>/dev/null) || {
        log_error "Failed to query GCP quotas for region ${region}"
        return 1
    }

    local gpu_metric cpu_metric
    case "$gpu" in
        t4)
            gpu_metric="NVIDIA_T4_GPUS"
            cpu_metric=""
            ;;
        l4)
            gpu_metric="NVIDIA_L4_GPUS"
            cpu_metric=""  # g2 uses standard CPU quota
            ;;
        a100)
            gpu_metric="NVIDIA_A100_GPUS"
            cpu_metric="A2_CPUS"
            ;;
        h100)
            gpu_metric="NVIDIA_H100_GPUS"
            cpu_metric=""  # Check A3 CPU quota
            ;;
    esac

    # Check GPU quota
    local gpu_limit gpu_usage
    gpu_limit=$(echo "$quota_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for q in data.get('quotas', []):
    if q['metric'] == '${gpu_metric}':
        print(int(q['limit']))
        sys.exit(0)
print(0)
" 2>/dev/null)
    gpu_usage=$(echo "$quota_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for q in data.get('quotas', []):
    if q['metric'] == '${gpu_metric}':
        print(int(q['usage']))
        sys.exit(0)
print(0)
" 2>/dev/null)

    local gpu_available=$(( gpu_limit - gpu_usage ))
    local gpu_needed
    gpu_needed=$(get_gpu_count gcp "$gpu")

    if (( gpu_limit == 0 )); then
        log_error "No ${gpu_metric} quota in ${region} (limit=0). Request quota increase at:"
        log_error "  https://console.cloud.google.com/iam-admin/quotas?project=${GCP_PROJECT}"
        return 1
    elif (( gpu_available < gpu_needed )); then
        log_error "${gpu_metric} quota insufficient in ${region}: available=${gpu_available}, needed=${gpu_needed}"
        return 1
    else
        log_success "${gpu_metric}: ${gpu_available} available (limit=${gpu_limit}, used=${gpu_usage})"
    fi

    # Check CPU quota if needed
    if [[ -n "$cpu_metric" ]]; then
        local cpu_limit
        cpu_limit=$(echo "$quota_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for q in data.get('quotas', []):
    if q['metric'] == '${cpu_metric}':
        print(int(q['limit']))
        sys.exit(0)
print(0)
" 2>/dev/null)

        local cpu_needed
        cpu_needed=$(get_instance_vcpus gcp "$gpu")

        if (( cpu_limit < cpu_needed )); then
            # Per-family quota is insufficient; check general CPUS quota as fallback
            local general_cpu_limit
            general_cpu_limit=$(echo "$quota_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for q in data.get('quotas', []):
    if q['metric'] == 'CPUS':
        print(int(q['limit']))
        sys.exit(0)
print(0)
" 2>/dev/null)
            local general_cpu_usage
            general_cpu_usage=$(echo "$quota_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for q in data.get('quotas', []):
    if q['metric'] == 'CPUS':
        print(int(q['usage']))
        sys.exit(0)
print(0)
" 2>/dev/null)
            local general_cpu_available=$(( general_cpu_limit - general_cpu_usage ))

            if (( general_cpu_available >= cpu_needed )); then
                log_warn "${cpu_metric} quota is ${cpu_limit}, but general CPUS quota covers it (available=${general_cpu_available})"
            else
                log_error "CPU quota insufficient in ${region}: ${cpu_metric}=${cpu_limit}, CPUS available=${general_cpu_available}, need ${cpu_needed}."
                log_error "  Request increase at: https://console.cloud.google.com/iam-admin/quotas?project=${GCP_PROJECT}"
                return 1
            fi
        else
            log_success "${cpu_metric}: limit=${cpu_limit} (need ${cpu_needed})"
        fi
    fi

    return 0
}

# Check AWS quota for a given region
check_aws_quota() {
    local gpu="$1" region="$2"

    log_info "Checking AWS quotas in ${region} for ${gpu}..."

    local quota_code
    case "$gpu" in
        t4)   quota_code="Running On-Demand G and VT instances" ;;
        a100) quota_code="Running On-Demand P instances" ;;
        h100) quota_code="Running On-Demand P instances" ;;
    esac

    local vcpu_limit
    vcpu_limit=$(aws service-quotas list-service-quotas \
        --service-code ec2 --region "$region" \
        --query "Quotas[?QuotaName=='${quota_code}'].Value" \
        --output text 2>/dev/null) || {
        log_error "Failed to query AWS quotas for region ${region}"
        return 1
    }

    local vcpu_needed
    vcpu_needed=$(get_instance_vcpus aws "$gpu")

    # Also account for control plane instances (~16 vCPUs for 3x m6i.xlarge)
    local total_needed=$(( vcpu_needed + 16 ))

    if [[ -z "$vcpu_limit" || "$vcpu_limit" == "None" ]]; then
        log_error "AWS vCPU quota not found in ${region} for ${quota_code}"
        log_error "  Request increase at: https://console.aws.amazon.com/servicequotas/"
        return 1
    fi

    if (( ${vcpu_limit%.*} < total_needed )); then
        log_error "AWS vCPU quota insufficient in ${region}: limit=${vcpu_limit}, need=${total_needed}"
        log_error "  Request increase at: https://console.aws.amazon.com/servicequotas/"
        return 1
    fi

    log_success "${quota_code}: limit=${vcpu_limit} vCPUs (need ~${total_needed})"

    # Verify credentials
    if ! aws sts get-caller-identity --region "$region" &>/dev/null; then
        log_error "AWS credentials not valid for region ${region}"
        return 1
    fi
    log_success "AWS credentials valid"
    return 0
}

# Main quota check dispatcher
check_quota() {
    local cloud="$1" gpu="$2" region="$3"

    log_phase "Pre-flight Quota Check"

    case "$cloud" in
        gcp) check_gcp_quota "$gpu" "$region" ;;
        aws) check_aws_quota "$gpu" "$region" ;;
        *)   log_error "Unknown cloud: $cloud"; return 1 ;;
    esac
}
