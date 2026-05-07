# AWS Authentication for Red Hat Users

## Overview

Red Hat uses SAML-based SSO for AWS access. This guide covers setting up temporary credentials for CLI and programmatic access.

## Prerequisites

- Active Red Hat Kerberos credentials
- VPN connection to Red Hat network
- Successfully logged into the AWS web console via SSO

## Installation

### Install AWS CLI (if not already installed)

```bash
# Option 1: Using system package manager
sudo dnf install -y awscli

# Option 2: Using pip
pip install awscli

# Option 3: Using Homebrew
brew install awscli
```

### Install Red Hat AWS Automation Tools

Install the Red Hat AWS automation tools:

```bash
# Install system dependencies
sudo dnf install -y python3-devel krb5-devel openldap-devel

# Create and activate a Python virtual environment (recommended)
python -m venv ~/.aws-saml-venv
source ~/.aws-saml-venv/bin/activate

# Install aws-automation tools (VPN required)
pip install --upgrade pip
pip install --upgrade git+https://gitlab.cee.redhat.com/compute/aws-automation.git
```

## Authentication Workflow

### Step 1: Obtain Kerberos Ticket

```bash
# Get a fresh Kerberos ticket
kinit your_kerberos_id@REDHAT.COM
# or
kinit your_kerberos_id@IPA.REDHAT.COM

# Enter your Kerberos password when prompted
```

**Note**: If you need to set/reset your Kerberos password, see: https://redhat.service-now.com/help?id=kb_article_view&sysparm_article=KB0000072

### Step 2: Run AWS SAML Authentication

```bash
# Activate the virtualenv if not already active
source ~/.aws-saml-venv/bin/activate

# Run the SAML authentication tool
aws-saml.py
```

You'll be prompted to select an AWS account role:

```
# You'll see a list of AWS accounts you have access to
# Select the appropriate account number for your role (admin or poweruser)

Please choose the role you would like to assume:
[0]: <account-role-1>
[1]: <account-role-2>
...

Selection: 0

-------------------------------------------------------------
 Your new access key pair has been stored in the AWS credentials
 file /home/your_kerberos_id/.aws/credentials under the "saml" profile.

 Note that it will expire at <timestamp>.

 To use this credential, call the AWS CLI with the --profile option
 (e.g. aws --profile "saml" ec2 describe-instances)
-------------------------------------------------------------
```

### Step 3: Use the Credentials

The credentials are stored under the `saml` profile. Use them in one of two ways:

**Option 1: Environment Variable (recommended for scripts)**
```bash
export AWS_PROFILE=saml
aws ec2 describe-instances
openshift-install create cluster
```

**Option 2: CLI Flag**
```bash
aws --profile saml ec2 describe-instances
```

## Using with OpenShift Installer

For cluster creation, set the `AWS_PROFILE` environment variable before running the installer:

```bash
# Set the profile
export AWS_PROFILE=saml

# Verify credentials are working
aws sts get-caller-identity

# Run cluster setup
${CLAUDE_PLUGIN_ROOT}/bin/setup.sh \
  --cluster-name my-cluster \
  --cloud aws \
  --pull-secret ~/openshift/pull-secret \
  --instance-type m6i.xlarge
```

## Credential Expiration

SAML credentials are temporary and expire after ~12 hours. When they expire:

1. Run `kinit` to refresh your Kerberos ticket (if needed)
2. Run `aws-saml.py` again to get fresh credentials
3. Continue working with `AWS_PROFILE=saml`

## Troubleshooting

### Command not found: aws-saml.py

**Solution**: Activate the virtualenv where you installed the tools:
```bash
source ~/.aws-saml-venv/bin/activate
```

### VPN Required Error

**Solution**: Connect to the Red Hat VPN before running `pip install` or `aws-saml.py`

### Invalid Kerberos Ticket

**Solution**: Get a fresh ticket:
```bash
kdestroy  # Clear old tickets
kinit your_kerberos_id@REDHAT.COM
```

### Expired Credentials

**Symptom**: AWS CLI returns "ExpiredToken" errors

**Solution**: Re-run `aws-saml.py` to refresh credentials

## References

- Full AWS SSO Documentation: https://source.redhat.com/departments/it/devit/it-infrastructure/itcloudservices/itpubliccloudpage/cloud/docs/consumer/using_ansible_and_the_cli_to_access_aws_in_a_saml_world
- AWS SSO Admin Guide: https://docs.google.com/document/d/1KoJtwzzcSDuMBhpKmdSk0a2YT0c9zuGMK2zGpTRcrAk/view
- AWS SSO User Guide: https://docs.google.com/document/d/1yziT4KU2BhreGP7r1c9LySoW_MseQ5dDqpp6Cm3-18M/view
