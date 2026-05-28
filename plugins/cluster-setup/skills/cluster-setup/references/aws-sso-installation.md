# AWS SSO Installation Guide

This guide covers OpenShift installation using AWS SSO credentials with restricted IAM roles.

**Prerequisites**: Complete the [AWS Authentication](aws-auth.md) setup first.

## AWS SSO Credentials Requirements

### Credentials Mode Requirement

When using temporary STS credentials from AWS SSO, you **must** use `credentialsMode: Manual` in your install-config.yaml. The OpenShift installer's credential validation is incompatible with AWS SSO session tokens.

**Symptom**: Installation fails with errors like:
- `AWS credentials provided by SharedConfigCredentials: /path/.aws/credentials are not valid for default credentials mode`
- `AWS credentials...are not valid for Passthrough credentials mode`

**Solution**: Add `credentialsMode: Manual` to your install-config.yaml:

```yaml
apiVersion: v1
metadata:
  name: my-cluster
baseDomain: your-base-domain.com
credentialsMode: Manual  # Required for SSO credentials
compute:
  - architecture: amd64
    # ... rest of config
```

**Note**: With Manual credentials mode, you'll need to manually handle CredentialRequests post-installation for cluster operators that require cloud credentials.

### Credential Expiration During Installation

AWS SSO session credentials have a limited lifetime (typically 15-60 minutes depending on your SSO configuration), but cluster installation takes 30-45 minutes. This can cause installation failures if credentials expire mid-installation.

**Workarounds**:
1. **Use Manual credentialsMode** (recommended): Bypasses credential validation during installation
2. **Write credentials to default profile**: Export SSO credentials to `~/.aws/credentials` default profile before installation:
   ```bash
   AWS_PROFILE=your-sso-profile aws configure export-credentials --format env > /tmp/aws-creds.env
   # Parse and write to ~/.aws/credentials [default] section
   ```

### AWS Login Command (Internal Tool)

Some Red Hat AWS environments use an `aws login` command that integrates with SSO. This command stores session metadata but may not work directly with openshift-install.

**Issue**: `aws login --profile my-profile` creates a session, but openshift-install cannot access the credentials.

**Solution**: After `aws login`, export the credentials to a profile that openshift-install can read:
```bash
aws login --profile my-profile
AWS_PROFILE=my-profile aws configure export-credentials --format env > /tmp/creds.env
# Write to ~/.aws/credentials or use credentialsMode: Manual
```

### Route53 Hosted Zone Requirements

The installer requires a Route53 hosted zone for the base domain to exist before installation.

**Check if zone exists**:
```bash
aws route53 list-hosted-zones-by-name --dns-name your-base-domain.com
```

**Create hosted zone if needed**:
```bash
aws route53 create-hosted-zone \
  --name your-base-domain.com \
  --caller-reference $(date +%s)
```

**Note**: With restricted IAM roles, you may not be able to list existing zones. Pre-create the zone with sufficient permissions before running the installer.

## Complete AWS SSO Installation Workflow

When using AWS SSO with restricted roles, follow this complete workflow:

### Step 1: Authenticate with AWS SSO
```bash
# Set AWS region first (required)
aws configure set region us-east-1 --profile openshift-installer-restricted

# Log in with your SSO profile
aws login --profile openshift-installer-restricted

# Verify credentials
AWS_PROFILE=openshift-installer-restricted aws sts get-caller-identity
```

### Step 2: Pre-create Route53 Hosted Zone

**Important**: The base domain for OpenShift Node Team is `openshift-node-team.devcluster.openshift.com`. The cluster-setup skill uses this as the default base domain. You typically do NOT need to create a subdomain - just ensure this base zone exists.

```bash
# Export credentials for use
AWS_PROFILE=openshift-installer-restricted aws configure export-credentials --format env > /tmp/aws-creds.env
source /tmp/aws-creds.env

# Check if the base zone already exists (it usually does)
aws route53 list-hosted-zones-by-name --dns-name openshift-node-team.devcluster.openshift.com

# Only create if it doesn't exist
aws route53 create-hosted-zone \
  --name openshift-node-team.devcluster.openshift.com \
  --caller-reference ocp-$(date +%s)
```

**Note**: The cluster name (e.g., `my-cluster`) becomes a subdomain automatically: `my-cluster.openshift-node-team.devcluster.openshift.com`

### Step 3: Export Credentials to Default Profile
```bash
# The cluster-setup skill currently doesn't support AWS_PROFILE pass-through
# Export credentials to default profile
AWS_PROFILE=openshift-installer-restricted aws configure export-credentials --format env > /tmp/creds.env

# Write to ~/.aws/credentials [default] section
cat > ~/.aws/credentials << EOF
[default]
$(grep AWS_ACCESS_KEY_ID /tmp/creds.env | sed 's/export AWS_ACCESS_KEY_ID=/aws_access_key_id = /')
$(grep AWS_SECRET_ACCESS_KEY /tmp/creds.env | sed 's/export AWS_SECRET_ACCESS_KEY=/aws_secret_access_key = /')
$(grep AWS_SESSION_TOKEN /tmp/creds.env | sed 's/export AWS_SESSION_TOKEN=/aws_session_token = /')
EOF

# Verify credentials work
aws sts get-caller-identity
```

### Step 4: Create Custom Install Config with credentialsMode
```bash
# The cluster-setup skill's install-config templates don't include credentialsMode
# Create a custom install-config.yaml
mkdir -p /tmp/ocp-my-cluster
cat > /tmp/ocp-my-cluster/install-config.yaml << EOF
apiVersion: v1
metadata:
  name: my-cluster
baseDomain: openshift-node-team.devcluster.openshift.com
credentialsMode: Manual  # Required for AWS SSO credentials
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform:
    aws:
      type: m6i.xlarge
      zones:
      - us-east-1a
  replicas: 1
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform: {}
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
    region: us-east-1
pullSecret: 'YOUR_PULL_SECRET_HERE'
sshKey: 'YOUR_SSH_PUBLIC_KEY_HERE'
EOF

# Back up the install-config (it gets consumed)
cp /tmp/ocp-my-cluster/install-config.yaml /tmp/ocp-my-cluster/install-config.yaml.bak
```

### Step 5: Run openshift-install Directly
```bash
# Download the installer if needed
INSTALLER_VERSION=4.21.0
mkdir -p ~/.local/share/cluster-setup/tools
cd ~/.local/share/cluster-setup/tools
wget "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${INSTALLER_VERSION}/openshift-install-linux.tar.gz"
tar -xzf openshift-install-linux.tar.gz

# Run the installer
~/.local/share/cluster-setup/tools/openshift-install create cluster \
  --dir=/tmp/ocp-my-cluster \
  --log-level=info
```

**Important**: AWS SSO credentials may expire during installation (typically 15-60 minutes). The installation takes 30-45 minutes, so credential expiration can cause failures. Consider using long-lived IAM user credentials for production installations.

## References

- OpenShift credentialsMode Documentation: https://docs.openshift.com/container-platform/4.21/installing/installing_aws/installing-aws-customizations.html#installation-configuration-parameters_installing-aws-customizations
