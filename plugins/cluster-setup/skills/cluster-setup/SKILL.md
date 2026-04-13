---
name: cluster-setup
description: Set up OpenShift clusters with optional NVIDIA GPU and DRA support on AWS and GCP
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/bin/*) Bash(oc:*) Bash(gcloud:*) Bash(aws:*) Bash(helm:*) Bash(kubectl:*)
---

# OpenShift Cluster Setup

Set up OpenShift clusters on AWS or GCP, optionally with NVIDIA GPU hardware and the DRA (Dynamic Resource Allocation) stack.

## Quick Start

```bash
# General-purpose cluster (no GPU)
${CLAUDE_PLUGIN_ROOT}/bin/setup.sh --cluster-name my-cluster --cloud aws --pull-secret ~/pull-secret.json --instance-type m6i.xlarge

# GPU cluster (hardware only, no DRA stack)
${CLAUDE_PLUGIN_ROOT}/bin/setup.sh --cluster-name gpu-test --cloud gcp --gpu t4 --pull-secret ~/pull-secret.json

# GPU cluster with full DRA stack (OCP 4.21+ required)
${CLAUDE_PLUGIN_ROOT}/bin/setup.sh --cluster-name dra-test --cloud gcp --gpu t4 --dra --pull-secret ~/pull-secret.json

# Teardown
${CLAUDE_PLUGIN_ROOT}/bin/teardown.sh --cluster-name my-cluster
```

## What Gets Installed

| Mode | Flag | Phases | OCP Version |
|------|------|--------|-------------|
| No GPU | `--instance-type m6i.xlarge` | Cluster creation only | Any |
| GPU hardware only | `--gpu t4` | Cluster + GPU instance + MachineSet patching | Any |
| GPU + DRA stack | `--gpu t4 --dra` | Cluster + feature gates + cert-manager + NFD + GPU Operator + DRA Driver | 4.21+ |

## GPU Decision Table

| GPU | AWS Instance | GCP Instance | MIG | Notes |
|-----|-------------|-------------|-----|-------|
| T4 | g4dn.xlarge | n1-standard-8 + accelerator | No | GCP needs post-install MachineSet patch |
| L4 | (GCP only) | g2-standard-8 | No | |
| A100 | p4d.24xlarge | a2-highgpu-1g | Yes | Cloud VMs need MIG workaround |
| H100 | p5.4xlarge | a3-highgpu-1g | Yes | Supports GPU reset natively |

## Key Commands

```bash
# Check cluster and GPU health
${CLAUDE_PLUGIN_ROOT}/bin/status.sh

# Resume from a failed DRA phase
${CLAUDE_PLUGIN_ROOT}/bin/setup.sh --cluster-name X --cloud gcp --gpu t4 --dra --skip-cluster --skip-to gpu-operator --pull-secret ~/ps.json
```

## Important

- `--dra` requires OCP 4.21+ (K8s 1.34+, `resource.k8s.io/v1`)
- Clusters cost money — destroy when done
- Zone fallback is automatic on capacity errors and instance-not-found errors (tries all zones twice)
- GCP T4 accelerator field in install-config is silently ignored — setup handles this via MachineSet patching

## References

Detailed guides loaded on demand:

* **GPU Matrix** — [references/gpu-matrix.md](references/gpu-matrix.md) — Instance types, zones, quota status, MIG capabilities
* **DRA Stack** — [references/dra-stack.md](references/dra-stack.md) — Feature gates, version compatibility, helm chart versions, namespaces
* **Workarounds** — [references/workarounds.md](references/workarounds.md) — A100 MIG on cloud VMs, T4 MachineSet patching, zone fallback, SCC grants
* **Error Recovery** — [references/error-recovery.md](references/error-recovery.md) — Error table, causes, fixes, resume commands
