# cluster-setup-with-gpu

Claude Code workspace for setting up OpenShift clusters with NVIDIA GPUs and DRA (Dynamic Resource Allocation) support.

## Slash Commands

- `/setup` — Interactive GPU cluster creation wizard
- `/teardown` — Remove resources or destroy cluster
- `/status` — Health check all components
- `/test` — Run GPU/DRA smoke tests

## GPU Instance Matrix

| GPU  | GCP Instance      | AWS Instance    | GPUs | MIG |
|------|-------------------|-----------------|------|-----|
| T4   | n1-standard-4 + nvidia-tesla-t4 accelerator | g4dn.xlarge | 1 | No |
| L4   | g2-standard-4     | (GCP only)      | 1    | No  |
| A100 | a2-highgpu-1g     | p4d.24xlarge    | 1/8  | Yes |
| H100 | a3-highgpu-1g     | p5.48xlarge     | 1/8  | Yes |

### Quota Status (as of March 2026)

**GCP (set via `GCP_PROJECT` env var):**
- T4: 16 GPUs quota in us-central1 — works
- A100: 10 GPUs quota but A2_CPUS=0 — needs CPU quota increase
- H100: No quota at all — needs quota request

**AWS (set via `AWS_PROFILE` or `~/.aws/credentials`):**
- T4: 920 G-instance vCPUs — works
- A100: 692 P-instance vCPUs — works
- H100: 692 P-instance vCPUs — works

## Setup Phases (in order)

1. **Quota check** — verify cloud has enough GPU/CPU quota
2. **Cluster creation** — openshift-install with zone fallback on stockout
3. **Feature gates** — enable DRA feature gates, wait for MCP rollout
4. **cert-manager** — install cert-manager operator
5. **NFD** — Node Feature Discovery + manual GPU labeling
6. **GPU Operator** — NVIDIA GPU Operator with DRA enabled, device plugin DISABLED
7. **DRA Driver** — NVIDIA DRA Driver (MIG mode auto-gated by GPU type)
8. **Smoke test** — submit GPU job, verify GPU access via DRA

Each phase has active monitoring: polls until success or timeout, surfaces pod logs/events on failure.

## Critical Workarounds

These are hard-won lessons — do not remove without understanding why they exist:

1. **install-config accelerators field is ignored** — for GCP T4, the accelerator field in install-config.yaml is silently ignored by the installer. The cluster must be created with `n1-standard-4` (no GPU), then the worker MachineSet is patched post-install to add `nvidia-tesla-t4` accelerator with `onHostMaintenance: Terminate`. The old worker is scaled down, patched, and scaled back up. A100/H100 use dedicated GPU instance types (a2/a3) so this is only needed for T4.

2. **devicePlugin.enabled=false** — MUST be false in GPU Operator when using DRA. If left true, the standard device plugin conflicts with the DRA driver.

3. **DynamicMIG=false for T4** — T4 GPUs do not support MIG partitioning. The DRA driver will fail if DynamicMIG is enabled on non-MIG hardware.

4. **Manual NFD node labeling** — automatic NFD detection can be slow or miss GPUs on fresh clusters. Scripts manually label nodes with `nvidia.com/gpu.present=true` as backup.

5. **SCC grants required** — OpenShift requires explicit Security Context Constraint grants for every NVIDIA service account. Missing grants cause pods to fail with permission denied.

6. **MachineSet patching for zone fallback** — when a zone runs out of GPU capacity, patch the MachineSet's zone field and delete failed machines. The MachineSet controller will create new machines in the new zone.

7. **SharedCounterSets timing** — with DynamicMIG, ResourceSlice may take up to 60s to update after MIG partition creation. Tests should wait for ResourceSlice to show the partition.

## Error Recovery

| Error | Cause | Fix |
|-------|-------|-----|
| Cluster create auth failure | Stale pull secret | Refresh at console.redhat.com |
| No worker node after 20 min | GPU stockout in zone | Auto zone fallback handles this |
| MCP Degraded | Feature gate conflict | Check `oc describe mcp`, may need to patch feature gates |
| GPU driver pod stuck in Init | Kernel module build failure | Delete pod, check driver toolkit image |
| No ResourceSlice | DRA driver permissions | Verify SCC grants for kubelet-plugin SA |
| nvidia-smi not found in pod | Wrong container image | Use CUDA-enabled image for GPU workloads |

## Key Namespaces

- `cert-manager` — cert-manager operator
- `node-feature-discovery` — NFD
- `nvidia-gpu-operator` — GPU Operator + driver
- `nvidia-dra-driver-gpu` — DRA driver (controller + kubelet-plugin)

## Environment Variables

| Var | Default | Description |
|-----|---------|-------------|
| `KUBECONFIG` | (from install dir) | Path to cluster kubeconfig |
| `OPENSHIFT_INSTALL` | `openshift-install` | Path to openshift-install binary |
| `GCP_PROJECT` | (required for GCP) | GCP project ID |
| `GCP_BASE_DOMAIN` | `gcp.devcluster.openshift.com` | GCP base domain |
| `AWS_BASE_DOMAIN` | `devcluster.openshift.com` | AWS base domain |
| `OCP_VERSION` | `4.21.0` | OpenShift version |
