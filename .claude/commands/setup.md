# GPU Cluster Setup

You are an interactive assistant that sets up an OpenShift 4.21 cluster with NVIDIA GPUs and DRA support.

## Step 1: Gather Parameters

Ask the user for:
1. **Cloud**: `aws` or `gcp`
2. **GPU type**: `t4`, `l4` (GCP only), `a100`, or `h100`
3. **Cluster name**: short name (e.g. `my-gpu-test`)
4. **Pull secret path**: path to their pull-secret.json file
5. **OCP version**: default `4.21.0`, or the version they want
6. **openshift-install path**: if they have a specific binary, ask for its path. Otherwise it will be auto-downloaded for the chosen OCP version
7. **MIG mode**: only ask if GPU is `a100` or `h100` — offer `timeslicing` (default) or `dynamicmig`

Auto-resolve region and zone from the GPU matrix. Validate the cloud+GPU combo:
- A100 on GCP: warn about A2_CPUS quota (may be 0, but general CPUS quota may cover it)
- H100 on GCP: warn about missing H100 quota
- T4: works on both clouds

### A100 + DynamicMIG Warning

If the user selects **A100** with **dynamicmig** on a cloud platform (GCP or AWS), present this warning before proceeding:

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
> 1. **H100** — supports GPU reset natively, DynamicMIG works without workarounds
> 2. **A100 with timeslicing** — no MIG partitioning, but avoids the GPU reset issue entirely
>
> Do you want to proceed with A100 + DynamicMIG (with workarounds), switch to H100, or use timeslicing instead?

Wait for the user's choice before continuing.

Present a summary that includes **all component versions** that will be installed:
- OCP version
- NFD chart version (default from config.sh)
- GPU Operator chart version (default from config.sh)
- DRA Driver chart version (default from config.sh)

Ask the user: "These are the versions that will be installed. Do you want to change any, or is there anything else needed before we start?"

If the user wants different versions, pass them via `--nfd-version`, `--gpu-operator-version`, or `--dra-driver-version` flags.

Confirm before proceeding.

## Step 2: Run Setup

Run `bin/setup.sh` with the gathered parameters:
```bash
bash bin/setup.sh \
  --cluster-name <name> \
  --cloud <cloud> \
  --gpu <gpu> \
  --pull-secret <path> \
  --ocp-version <version> \
  --openshift-install <path-if-provided> \
  --mig-mode <mode> \
  --smoke-test
```

Monitor the output. After each phase completes, briefly report status to the user.

## Step 3: Handle Failures

If any phase fails:
1. Show the relevant error from the output
2. Suggest the fix (check the Error Recovery section in CLAUDE.md)
3. Offer to resume from the failed phase using `--skip-to <phase>`

## Interaction Pattern

- Confirm before starting (this creates cloud resources that cost money)
- Show progress at each phase boundary
- If cluster creation reports a zone stockout, explain the auto-fallback
- At the end, show the KUBECONFIG export command and suggest next steps
