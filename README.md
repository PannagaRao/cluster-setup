# cluster-setup

A Claude Code workspace for setting up OpenShift clusters, optionally with NVIDIA GPUs and DRA (Dynamic Resource Allocation) support.

## Prerequisites

- [Claude Code](https://claude.ai/code) CLI
- `openshift-install` binary on PATH (auto-downloaded if missing)
- `oc` CLI
- `helm` CLI
- `gcloud` CLI (for GCP) or `aws` CLI (for AWS)
- A valid [Red Hat pull secret](https://console.redhat.com/openshift/install/pull-secret)
- SSH key pair (`~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub`)

## Quick Start

```bash
# Clone the repo
git clone https://github.com/PannagaRao/cluster-setup.git
cd cluster-setup

# Use Claude Code slash commands
claude

# Then type:
/setup
```

The `/setup` wizard walks you through: cloud provider, region, instance type selection (queried live from cloud APIs), and optional GPU/DRA operator stack installation.

Or run directly:

```bash
# General-purpose cluster (no GPU)
bash bin/setup.sh \
  --cluster-name my-cluster \
  --cloud aws \
  --instance-type m6i.xlarge \
  --pull-secret ~/.pull-secret.json

# T4 on AWS (GPU auto-detected from instance type)
bash bin/setup.sh \
  --cluster-name my-test \
  --cloud aws \
  --instance-type g4dn.xlarge \
  --pull-secret ~/.pull-secret.json

# A100 on GCP with DynamicMIG
bash bin/setup.sh \
  --cluster-name mig-test \
  --cloud gcp \
  --gpu a100 \
  --pull-secret ~/.pull-secret.json \
  --mig-mode dynamicmig

# Resume from a specific phase
bash bin/setup.sh \
  --cluster-name my-test \
  --cloud aws \
  --gpu t4 \
  --pull-secret ~/.pull-secret.json \
  --skip-to dra-driver
```

## Slash Commands

| Command | Description |
|---------|-------------|
| `/setup` | Interactive cluster creation wizard (GPU optional) |
| `/teardown` | Remove resources or destroy cluster |
| `/status` | Health check all components |
| `/test` | Run GPU/DRA smoke tests |

## GPU Matrix

| GPU | GCP | AWS | MIG |
|-----|-----|-----|-----|
| T4 | `n1-standard-8` + `nvidia-tesla-t4` | `g4dn.xlarge` | No |
| L4 | `g2-standard-8` | (GCP only) | No |
| A100 | `a2-highgpu-1g` | `p4d.24xlarge` | Yes |
| H100 | `a3-highgpu-1g` | `p5.4xlarge` | Yes |

## What Gets Installed

**Non-GPU cluster:** OpenShift cluster only.

**GPU+DRA cluster:** All of the above, plus:
1. DRA feature gates (DynamicResourceAllocation, DRAPartitionableDevices, etc.)
2. cert-manager operator
3. Node Feature Discovery (NFD)
4. NVIDIA GPU Operator (with DRA enabled, device plugin disabled)
5. NVIDIA DRA Driver (TimeSlicing or DynamicMIG mode)

## Smart Features

- **Instance type discovery**: queries cloud APIs for available machine types
- **GPU auto-detection**: detects GPU type from instance family (g4dn -> T4, g2 -> L4, etc.)
- **Pre-flight quota checks**: verifies GPU and CPU quotas before creating anything
- **Zone fallback on stockout**: if a zone runs out of GPU capacity, automatically switches to the next available zone
- **Parallel worker monitoring**: monitors worker provisioning during cluster creation, not after
- **Install-config review**: shows the generated install-config.yaml before creating the cluster
- **MIG auto-gating**: DynamicMIG is only enabled on MIG-capable GPUs (A100, H100)
- **Resume support**: `--skip-to <phase>` lets you restart from any phase

## Teardown

```bash
# Remove GPU/DRA resources (keep cluster) -- auto-detects if GPU resources exist
bash bin/teardown.sh --resources-only --cluster-name my-test

# Destroy everything
bash bin/teardown.sh --cluster-name my-test
```

## Status Check

```bash
bash bin/status.sh
```
