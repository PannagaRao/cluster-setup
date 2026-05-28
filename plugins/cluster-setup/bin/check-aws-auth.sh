#!/usr/bin/env bash
# Check AWS authentication status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
source "${LIB_DIR}/config.sh"

log_phase "AWS Authentication Check"

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    log_error "AWS CLI is not installed"
    echo "  Install with: sudo dnf install -y awscli  OR  brew install awscli"
    exit 1
fi
log_success "AWS CLI installed: $(aws --version 2>&1 | head -1)"

# Check for credentials
IDENTITY=$(aws sts get-caller-identity 2>/dev/null || true)
if [[ -z "$IDENTITY" ]]; then
    log_error "AWS credentials are not configured or have expired"
    echo "  See: ${SCRIPT_DIR}/../skills/cluster-setup/references/aws-auth.md"
    echo "  Or run: aws login --profile <your-profile>"
    exit 1
fi
log_success "AWS credentials valid"
echo "  User/Role: $(echo "$IDENTITY" | python3 -c "import json,sys; print(json.load(sys.stdin)['Arn'])" 2>/dev/null || echo "unknown")"
echo "  Account:   $(echo "$IDENTITY" | python3 -c "import json,sys; print(json.load(sys.stdin)['Account'])" 2>/dev/null || echo "unknown")"

# Check for Route53 access
if aws route53 list-hosted-zones --max-items 1 &>/dev/null; then
    log_success "Route53 access confirmed"
else
    log_warn "Cannot list Route53 zones (may be restricted by IAM role)"
    echo "  You may need to pre-create hosted zones before installation"
fi

log_phase "AWS authentication check complete"
