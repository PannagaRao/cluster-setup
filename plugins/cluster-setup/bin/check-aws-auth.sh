#!/usr/bin/env bash
# Check if AWS credentials are configured and provide setup guidance if not
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "${SCRIPT_DIR}")/skills/cluster-setup"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found. Please install it:"
        echo "  sudo dnf install -y awscli"
        echo "  or: pip install awscli"
        return 1
    fi
    return 0
}

check_credentials() {
    local profile="${1:-}"

    if [[ -n "$profile" ]]; then
        if aws --profile "$profile" sts get-caller-identity &> /dev/null; then
            return 0
        fi
    else
        if aws sts get-caller-identity &> /dev/null; then
            return 0
        fi
    fi
    return 1
}

show_saml_setup() {
    cat <<EOF

${YELLOW}========================================
AWS SAML Authentication Setup Required
========================================${NC}

You need to configure AWS credentials using Red Hat's SAML-based SSO.

${GREEN}Quick Start:${NC}

1. Install aws-automation tools (VPN required):
   ${YELLOW}sudo dnf install -y python3-devel krb5-devel openldap-devel
   python -m venv ~/.aws-saml-venv
   source ~/.aws-saml-venv/bin/activate
   pip install --upgrade pip
   pip install --upgrade git+https://gitlab.cee.redhat.com/compute/aws-automation.git${NC}

2. Get Kerberos ticket:
   ${YELLOW}kinit your_kerberos_id@REDHAT.COM${NC}

3. Run SAML authentication:
   ${YELLOW}source ~/.aws-saml-venv/bin/activate
   aws-saml.py${NC}

   Select your account/role when prompted

4. Set the AWS profile:
   ${YELLOW}export AWS_PROFILE=saml${NC}

5. Verify credentials:
   ${YELLOW}aws sts get-caller-identity${NC}

${GREEN}For detailed instructions, see:${NC}
  ${SKILL_DIR}/references/aws-auth.md

EOF
}

main() {
    local profile="${AWS_PROFILE:-}"

    log_info "Checking AWS authentication..."

    # Check if AWS CLI is installed
    if ! check_aws_cli; then
        exit 1
    fi

    # Check for credentials with current profile or default
    if check_credentials "$profile"; then
        log_info "AWS credentials are configured!"

        # Show current identity
        echo ""
        if [[ -n "$profile" ]]; then
            aws --profile "$profile" sts get-caller-identity
        else
            aws sts get-caller-identity
        fi

        exit 0
    fi

    # No credentials found
    log_warn "No valid AWS credentials found."

    # Check if this looks like a Red Hat environment
    if [[ -f /etc/redhat-release ]] || [[ "${USER}" == *"redhat"* ]]; then
        show_saml_setup
    else
        echo ""
        log_info "Please configure AWS credentials using one of these methods:"
        echo "  1. AWS SSO: aws configure sso"
        echo "  2. IAM credentials: aws configure"
        echo "  3. Environment variables: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY"
        echo ""
        log_info "For Red Hat users with SAML-based SSO, see:"
        echo "  ${SKILL_DIR}/references/aws-auth.md"
    fi

    exit 1
}

main "$@"
