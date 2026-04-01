#!/usr/bin/env bash
# Check GPU instance type availability (runs quietly, exit 0=available, 1=unavailable)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/config.sh"

CLOUD="${1:-}"
GPU="${2:-}"
REGION="${3:-}"

[[ -z "$CLOUD" || -z "$GPU" ]] && exit 1

INSTANCE_TYPE=$(get_instance_type "$CLOUD" "$GPU") || exit 1
[[ -z "$REGION" ]] && REGION=$(get_default_region "$CLOUD" "$GPU")

case "$CLOUD" in
    aws)
        check_aws_available_quiet "$INSTANCE_TYPE" "$REGION" || exit 1
        ;;
    gcp)
        exit 0  # Skip GCP checks for now
        ;;
    *)
        exit 1
        ;;
esac
