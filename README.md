# cluster-setup

A Claude Code plugin marketplace for setting up OpenShift clusters on AWS and GCP, with optional NVIDIA GPU hardware and DRA (Dynamic Resource Allocation) stack.

## Install as Plugin

```bash
/plugin marketplace add PannagaRao/cluster-setup
/plugin install cluster-setup@cluster-setup
```

Then use from any directory:

```
/cluster-setup:setup       # Interactive cluster creation wizard
/cluster-setup:teardown    # Destroy cluster or remove DRA resources
/cluster-setup:status      # Health check all components
/cluster-setup:test        # Run GPU/DRA smoke tests
```

## Quick Start

The `/cluster-setup:setup` wizard walks you through cloud provider, region, instance type, GPU selection, and optional DRA stack installation.

Or run scripts directly:

```bash
# General-purpose cluster (no GPU)
bash plugins/cluster-setup/bin/setup.sh \
  --cluster-name my-cluster \
  --cloud aws \
  --instance-type m6i.xlarge \
  --pull-secret ~/.pull-secret.json

# T4 GPU hardware only (no DRA stack)
bash plugins/cluster-setup/bin/setup.sh \
  --cluster-name gpu-test \
  --cloud gcp \
  --gpu t4 \
  --pull-secret ~/.pull-secret.json

# T4 GPU with DRA stack (OCP 4.21+ required)
bash plugins/cluster-setup/bin/setup.sh \
  --cluster-name dra-test \
  --cloud gcp \
  --gpu t4 \
  --dra \
  --pull-secret ~/.pull-secret.json

# A100 with DRA + DynamicMIG, 2 workers
bash plugins/cluster-setup/bin/setup.sh \
  --cluster-name mig-test \
  --cloud gcp \
  --gpu a100 \
  --dra \
  --mig-mode dynamicmig \
  --workers 2 \
  --pull-secret ~/.pull-secret.json

# Resume from a specific phase
bash plugins/cluster-setup/bin/setup.sh \
  --cluster-name dra-test \
  --cloud gcp \
  --gpu t4 \
  --dra \
  --pull-secret ~/.pull-secret.json \
  --skip-cluster \
  --skip-to gpu-operator
```

## Prerequisites

- [Claude Code](https://claude.ai/code) CLI (for plugin usage)
- `oc` CLI
- `helm` CLI
- `gcloud` CLI (for GCP) or `aws` CLI (for AWS)
- A valid [Red Hat pull secret](https://console.redhat.com/openshift/install/pull-secret)
- SSH key pair (`~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub`)
- `openshift-install` is auto-downloaded (stable or candidate) based on `--ocp-version`

## GPU Matrix

| GPU | GCP | AWS | MIG |
|-----|-----|-----|-----|
| T4 | `n1-standard-8` + `nvidia-tesla-t4` | `g4dn.xlarge` | No |
| L4 | `g2-standard-8` | (GCP only) | No |
| A100 | `a2-highgpu-1g` | `p4d.24xlarge` | Yes |
| H100 | `a3-highgpu-1g` | `p5.4xlarge` | Yes |

## What Gets Installed

| Mode | Flag | What runs |
|------|------|-----------|
| No GPU | `--instance-type m6i.xlarge` | Cluster only |
| GPU hardware | `--gpu t4` | Cluster + GPU instance + MachineSet patching |
| GPU + DRA | `--gpu t4 --dra` | Cluster + feature gates + cert-manager + NFD + GPU Operator + DRA Driver |

`--dra` requires OCP 4.21+ (K8s 1.34+, `resource.k8s.io/v1`).

## OCP Version Support

- **Stable releases** (4.18, 4.21, etc.) — auto-downloaded from mirror.openshift.com
- **Candidate/nightly** (4.22, etc.) — auto-falls back to `ocp-dev-preview/candidate-4.22` if stable is unavailable. Requires `registry.ci.openshift.org` auth in pull secret.

## Key Features

- **`--dra` flag** — GPU hardware and DRA stack are independent. GPU without DRA works on any OCP version.
- **`--workers N`** — multiple worker nodes (default 1)
- **Zone fallback** — automatic retry across zones on capacity errors or instance-not-found, tries all zones twice
- **Stuck provisioning detection** — machines with no providerID after 5 min trigger zone fallback
- **Bootstrap-aware monitoring** — GCP waits for bootstrap complete before worker polling
- **Install-config editing** — review and modify the generated config before cluster creation
- **Error recovery** — on failure, shows destroy/resume commands with exact flags
- **MIG activation phase** — `--skip-to mig-activate` to resume A100 DynamicMIG reboot
- **Pull secret auto-detection** — accepts both raw JSON and `pullSecret: '...'` YAML format

## Teardown

```bash
# Destroy cluster (auto-detects and removes DRA resources if present)
bash plugins/cluster-setup/bin/teardown.sh --cluster-name my-test
```
