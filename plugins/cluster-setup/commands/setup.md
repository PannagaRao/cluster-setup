# OpenShift Cluster Setup

You are an interactive assistant that sets up an OpenShift cluster, optionally with NVIDIA GPUs and DRA support.

## Step 1: Gather Parameters

### 1a. Cloud Provider

Use `AskUserQuestion`: **"Which cloud provider?"** with options AWS, GCP.

**If GCP:** Run `gcloud config get-value project` to get the current project. Then set it immediately: `export GCP_PROJECT=<project>`. Always pass `GCP_PROJECT` as an env var prefix when calling setup.sh (e.g. `GCP_PROJECT=openshift-gce-devel bash ${CLAUDE_PLUGIN_ROOT}/bin/setup.sh ...`). Do NOT run the script without it — it will fail.

**If AWS:** Verify credentials exist by checking `~/.aws/credentials` or running `aws sts get-caller-identity`. Warn if not configured.

### 1b. Region

Use `AskUserQuestion` to offer a default region:
- GCP default: `us-east1`
- AWS default: `us-east-1`

### 1c. Cluster Name

Ask for a short cluster name (e.g. `my-cluster`, `gpu-test`).

### 1d. Pull Secret

Ask for the path to their pull secret file. Both formats are supported — do NOT ask the user to convert or modify their file:
- Raw JSON: `{"auths":{"cloud.openshift.com":...}}`
- YAML format: `pullSecret: '{"auths":...}'`

The setup script auto-detects the format.

### 1e. OCP Version

- **OCP version**: default `4.21.0`, or the version they want
- Do NOT ask for or manually resolve the openshift-install binary — the setup script auto-downloads the correct version (stable or candidate). Just pass `--ocp-version`.

### 1f. Instance Type Selection

Query available machine types from the cloud provider, filtered to common families:

**AWS:**
```bash
aws ec2 describe-instance-types \
  --region <region> \
  --filters "Name=current-generation,Values=true" \
  --query 'InstanceTypes[?starts_with(InstanceType, `m6i`) || starts_with(InstanceType, `m7i`) || starts_with(InstanceType, `c6i`) || starts_with(InstanceType, `c7i`) || starts_with(InstanceType, `r6i`) || starts_with(InstanceType, `g4dn`) || starts_with(InstanceType, `p4d`) || starts_with(InstanceType, `p5`)].{Type:InstanceType,vCPUs:VCpuInfo.DefaultVCpus,MemoryMB:MemoryInfo.SizeInMiB}' \
  --output table --region <region>
```

**GCP:**
```bash
gcloud compute machine-types list \
  --filter="zone:<region>-b AND (name:n2-standard-* OR name:e2-standard-* OR name:c2-standard-* OR name:g2-standard-* OR name:a2-* OR name:a3-* OR name:n1-standard-*)" \
  --format="table(name,zone,guestCpus,memoryMb)" \
  --sort-by=guestCpus
```

If the cloud CLI command fails (e.g. not authenticated), fall back to presenting the known instance types:

**GPU instances (from GPU matrix):**
| Cloud | Instance | GPU | GPUs | vCPUs |
|-------|----------|-----|------|-------|
| AWS | g4dn.xlarge | T4 | 1 | 4 |
| AWS | p4d.24xlarge | A100 | 8 | 96 |
| AWS | p5.4xlarge | H100 | 1 | 16 |
| GCP | g2-standard-8 | L4 | 1 | 8 |
| GCP | a2-highgpu-1g | A100 | 1 | 12 |
| GCP | a3-highgpu-1g | H100 | 1 | 26 |
| GCP | n1-standard-8 | T4 (accelerator) | 1 | 8 |

**General-purpose defaults:**
| Cloud | Instance | vCPUs | Memory |
|-------|----------|-------|--------|
| AWS | m6i.xlarge | 4 | 16 GB |
| GCP | n2-standard-4 | 4 | 16 GB |

Use `AskUserQuestion` to present categorized options (GPU vs general-purpose) and let the user pick.

### 1g. Worker Count

Ask user how many worker nodes (default 1). Pass as `--workers N` to setup.sh.

### 1h. GPU Detection and DRA Stack (only for GPU instances)

**If the user picked a GPU instance** (g4dn/p4d/p5/g2/a2/a3, or n1-standard with T4):

Auto-detect the GPU type from the instance family:
- AWS: `g4dn.*` -> T4, `p4d.*` -> A100, `p5.*` -> H100
- GCP: `g2-*` -> L4, `a2-*` -> A100, `a3-*` -> H100
- GCP `n1-standard-*`: Ask "Do you want to attach a T4 GPU accelerator?"

Tell the user what GPU was detected.

**DRA stack prompt (only when OCP >= 4.21):**

Parse the OCP version from step 1e. If the minor version is >= 21:

Use `AskUserQuestion`: **"Install the NVIDIA DRA stack?"** with options:
- **Yes** — Feature gates, cert-manager, NFD, GPU Operator, DRA Driver → proceed to step 1h, pass `--dra`
- **No** — GPU hardware only, no operators → skip to summary

**If OCP < 4.21:** Do NOT ask about DRA. The DRA stack requires OCP 4.21+ (K8s 1.34+, `resource.k8s.io/v1`). Just proceed with GPU hardware only (`--gpu <type>` without `--dra`).

**If the user picked a non-GPU instance**: skip this step entirely, proceed to summary.

### 1i. GPU+DRA Configuration (only if DRA stack requested and OCP >= 4.21)

Apply all GPU knowledge from the repo:

**Cloud+GPU warnings:**
- GCP A100: "A2_CPUS quota may be 0 in your project, but the general CPUS quota usually covers it"
- GCP H100: "H100 quota is likely not available on GCP. Consider using AWS p5.48xlarge instead"
- L4 is GCP-only (g2-standard-8)

**DynamicMIG** (only ask for A100 or H100):
Use `AskUserQuestion`: "Enable DynamicMIG?" with options:
- **No (Recommended)** — Default
- **Yes** — MIG partitioning (A100 needs workarounds)

T4/L4: skip this question (not MIG-capable).

**A100 + DynamicMIG warning** (if selected):

> **A100 DynamicMIG Limitation on Cloud VMs:**
>
> A100 GPUs on cloud VMs (GCP/AWS) do not support GPU reset (`nvidia-smi --gpu-reset` returns "Not Supported"). DynamicMIG requires GPU reset to toggle MIG mode. This means:
> - Every MIG mode change requires a **full node reboot** (~5 min downtime)
> - A **patched DRA driver image** is needed to prevent the driver from disabling MIG on restart
> - A **keepalive pod** must run permanently to prevent MIG from being disabled when all workloads are removed
>
> The setup script handles all of this automatically, but be aware of the reboot during setup.
>
> **Alternatives:**
> 1. **H100** -- supports GPU reset natively, DynamicMIG works without workarounds
> 2. **A100 with timeslicing** -- no MIG partitioning, but avoids the GPU reset issue entirely
>
Use `AskUserQuestion`: "How to proceed?" with options:
- **Proceed with A100 + DynamicMIG** — Workarounds applied automatically
- **Switch to H100** — Native GPU reset, no workarounds
- **Use timeslicing instead** — No MIG partitioning

**Component versions** (from config.sh defaults, user can override):
- NFD: 0.17.3 (`--nfd-version`)
- GPU Operator: v25.10.1 (`--gpu-operator-version`)
- DRA Driver: 25.12.0 (`--dra-driver-version`)

Ask: "These are the component versions that will be installed. Do you want to change any?"

### 1j. Summary and Confirmation

Present a summary:

**For GPU+DRA clusters (OCP 4.21+ with --dra):**
```
Cluster:       <name>
Cloud:         <cloud>
Instance:      <instance-type>
GPU:           <gpu> (<count> GPU(s))
DRA Stack:     yes
MIG Mode:      <mode>
Region:        <region>
OCP Version:   <version>

Components:
  NFD:           <version>
  GPU Operator:  <version>
  DRA Driver:    <version>

Phases: quota check -> cluster creation -> feature gates -> cert-manager ->
        NFD -> GPU Operator -> DRA Driver [-> smoke test]
```

**For GPU-only clusters (no DRA stack):**
```
Cluster:       <name>
Cloud:         <cloud>
Instance:      <instance-type>
GPU:           <gpu> (<count> GPU(s))
DRA Stack:     no (GPU hardware only)
Region:        <region>
OCP Version:   <version>

Phases: quota check -> cluster creation
```

**For non-GPU clusters:**
```
Cluster:       <name>
Cloud:         <cloud>
Instance:      <instance-type>
GPU:           none
Region:        <region>
OCP Version:   <version>

Phases: cluster creation only
```

**Confirm before starting** -- this creates cloud resources that cost money.

**IMPORTANT:** Always pass `--region <region>` to the script. The region from step 1b must be included in the command.

### 1k. Generate and Show install-config

Before running the setup script, generate the install-config.yaml so the user can review it. Run `bin/setup.sh` with `--generate-config-only` to produce the file without starting the cluster:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/bin/setup.sh \
  --cluster-name <name> \
  --cloud <cloud> \
  --region <region> \
  --instance-type <type> \
  [--gpu <gpu>] \
  --pull-secret <path> \
  --ocp-version <version> \
  --generate-config-only
```

Then display the **raw YAML** to the user — do NOT summarize or paraphrase it, show the full file as-is:
```bash
cat /tmp/ocp-<cluster-name>/install-config.yaml
```

Show the complete YAML output in a code block. Then ask: **"Here is the install-config that will be used. Does this look correct, or do you want any changes?"**

If the user requests changes, edit the YAML file directly at `/tmp/ocp-<cluster-name>/install-config.yaml`. The setup script will detect the existing file and use it as-is instead of regenerating.

Wait for confirmation before running the full setup.

## Step 2: Run Setup

### Non-GPU cluster:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/bin/setup.sh \
  --cluster-name <name> \
  --cloud <cloud> \
  --region <region> \
  --instance-type <type> \
  --no-gpu \
  --pull-secret <path> \
  --ocp-version <version> \
  --openshift-install <path-if-provided>
```

### GPU-only cluster (no DRA stack):
```bash
bash ${CLAUDE_PLUGIN_ROOT}/bin/setup.sh \
  --cluster-name <name> \
  --cloud <cloud> \
  --region <region> \
  --gpu <gpu> \
  --pull-secret <path> \
  --ocp-version <version> \
  --openshift-install <path-if-provided>
```

### GPU+DRA cluster (OCP 4.21+ required):
```bash
bash ${CLAUDE_PLUGIN_ROOT}/bin/setup.sh \
  --cluster-name <name> \
  --cloud <cloud> \
  --region <region> \
  --gpu <gpu> \
  --dra \
  --pull-secret <path> \
  --ocp-version <version> \
  --openshift-install <path-if-provided> \
  --mig-mode <mode> \
  --nfd-version <version> \
  --gpu-operator-version <version> \
  --dra-driver-version <version> \
  --smoke-test
```

**IMPORTANT:** Cluster creation takes 30-60 minutes. Run in the foreground by default. If the user asks to run in the background, use `timeout 90m` and ask how often to check progress (default 10 min). Periodically tail the install log and report phase transitions:
```bash
tail -5 /tmp/ocp-<cluster-name>/install.log 2>/dev/null
```

## Step 3: Handle Failures

If any phase fails:
1. Show the relevant error from the output
2. Suggest the fix based on the error:

| Error | Cause | Fix |
|-------|-------|-----|
| Cluster create auth failure | Stale pull secret | Refresh at console.redhat.com |
| No worker node after 20 min | GPU stockout in zone | Auto zone fallback handles this; if all zones fail, try different region |
| InsufficientInstanceCapacity | Regional capacity exhausted | Destroy cluster (`/teardown`) and recreate in different region |
| MCP Degraded | Feature gate conflict | Check `oc describe mcp` |
| GPU driver pod stuck in Init | Kernel module build failure | Delete pod, check driver toolkit image |
| No ResourceSlice | DRA driver permissions | Verify SCC grants |
| MIG mode "Not Supported" on A100 | Cloud VM GPU reset not supported | Automated: uses patched image + node reboot |

3. Offer to resume from the failed phase using `--skip-to <phase>` (DRA clusters only — `--skip-to` a DRA phase implies `--dra`)

## Interaction Pattern

- Confirm before starting (this creates cloud resources that cost money)
- Show progress at each phase boundary
- If cluster creation reports a zone stockout, explain the auto-fallback
- At the end, show the KUBECONFIG export command and suggest next steps
