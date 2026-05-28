#!/usr/bin/env bash
# Check AWS authentication status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
source "${LIB_DIR}/config.sh"

echo "========================================="
echo " AWS Authentication Check"
echo "========================================="
echo

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "❌ AWS CLI is not installed"
    echo
    echo "Install with:"
    echo "  sudo dnf install -y awscli"
    echo "  OR"
    echo "  brew install awscli"
    exit 1
fi

echo "✓ AWS CLI is installed: $(aws --version)"
echo

# Check for credentials
if ! aws sts get-caller-identity &>/dev/null; then
    echo "❌ AWS credentials are not configured or have expired"
    echo
    echo "See the AWS authentication guide for setup:"
    echo "  ${SCRIPT_DIR}/../skills/cluster-setup/references/aws-auth.md"
    echo
    echo "Or run:"
    echo "  aws login --profile <your-profile>"
    exit 1
fi

# Get caller identity
IDENTITY=$(aws sts get-caller-identity)
echo "✓ AWS credentials are valid"
echo
echo "Current AWS Identity:"
echo "$IDENTITY" | jq -r '"  User/Role: \(.Arn)"'
echo "$IDENTITY" | jq -r '"  Account:   \(.Account)"'
echo

# Check for Route53 access
if aws route53 list-hosted-zones --max-items 1 &>/dev/null; then
    echo "✓ Route53 access confirmed"
else
    echo "⚠ Cannot list Route53 zones (may be restricted by IAM role)"
    echo "  This is normal for restricted installer roles"
    echo "  You may need to pre-create hosted zones before installation"
fi

echo
echo "========================================="
echo "AWS authentication check complete"
echo "========================================="
