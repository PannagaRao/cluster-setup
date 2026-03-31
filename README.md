# cluster-setup-with-gpu

A Claude Code workspace for setting up OpenShift 4.21 clusters with NVIDIA GPUs and DRA (Dynamic Resource Allocation) support.

## Prerequisites

- [Claude Code](https://claude.ai/code) CLI
- `openshift-install` binary (4.21+) on PATH
- `oc` CLI
- `helm` CLI
- `gcloud` CLI (for GCP) or `aws` CLI (for AWS)
- A valid [Red Hat pull secret](https://console.redhat.com/openshift/install/pull-secret)
- SSH key pair (`~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub`)

## Quick Start

```bash
# Clone the repo
git clone https://github.com/PannagaRao/cluster-setup-with-gpu.git
cd cluster-setup-with-gpu

# Use Claude Code slash commands
claude

# Then type:
/setup
```

Or run directly:

```bash
# T4 on AWS (cheapest option, ~$0.50/hr)
bash bin/setup.sh \
  --cluster-name my-test \
  --cloud aws \
  --gpu t4 \
  --pull-secret ~/.pull-secret.json \
  --smoke-test

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
| `/setup` | Interactive cluster creation wizard |
| `/teardown` | Remove resources or destroy cluster |
| `/status` | Health check all components |
| `/test` | Run GPU/DRA smoke tests |

## GPU Matrix

| GPU | GCP | AWS | MIG | Cost |
|-----|-----|-----|-----|------|
| T4 | `g2-standard-4` | `g4dn.xlarge` | No | ~$0.50/hr |
| A100 | `a2-highgpu-1g` | `p4d.24xlarge` | Yes | ~$3.67/hr |
| H100 | `a3-highgpu-1g` | `p5.48xlarge` | Yes | ~$32/hr |

## What Gets Installed

1. OpenShift 4.21 cluster with GPU worker nodes
2. DRA feature gates (DynamicResourceAllocation, DRAPartitionableDevices, etc.)
3. cert-manager operator
4. Node Feature Discovery (NFD)
5. NVIDIA GPU Operator (with DRA enabled, device plugin disabled)
6. NVIDIA DRA Driver (TimeSlicing or DynamicMIG mode)

## Smart Features

- **Pre-flight quota checks**: verifies GPU and CPU quotas before creating anything
- **Zone fallback on stockout**: if a zone runs out of GPU capacity, automatically switches to the next available zone
- **Active monitoring**: every phase polls until ready or timeout, with log/event surfacing on failure
- **MIG auto-gating**: DynamicMIG is only enabled on MIG-capable GPUs (A100, H100)
- **Resume support**: `--skip-to <phase>` lets you restart from any phase

## Teardown

```bash
# Remove GPU/DRA resources (keep cluster)
bash bin/teardown.sh --resources-only --cluster-name my-test

# Destroy everything
bash bin/teardown.sh --cluster-name my-test
```

## Status Check

```bash
bash bin/status.sh
```
