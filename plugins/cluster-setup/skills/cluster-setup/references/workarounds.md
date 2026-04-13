# Workarounds

Hard-won lessons — do not remove without understanding why they exist.

## 1. GCP T4 install-config accelerator field is ignored

The accelerator field in install-config.yaml is silently ignored by the installer. The cluster must be created with `n1-standard-8` (no GPU), then the worker MachineSet is patched post-install to add `nvidia-tesla-t4` accelerator with `onHostMaintenance: Terminate`. The old worker is scaled down, patched, and scaled back up. A100/H100 use dedicated GPU instance types so this is only needed for T4.

## 2. GCP GPU instances require onHostMaintenance: Terminate

All GPU instance types on GCP require `onHostMaintenance: Terminate` in the install-config. The installer defaults to `MIGRATE`, which GCP rejects. This is set in install-config generation.

## 3. Zone fallback with subnet patching

When a zone runs out of GPU capacity or an instance vanishes (`Instance not found on provider`), the scripts automatically try the next zone. All zones are tried twice before giving up.

**AWS** requires patching both the zone AND the subnet filter:
```bash
oc patch machineset $MS -n openshift-machine-api --type=merge \
  -p '{"spec":{"template":{"spec":{"providerSpec":{"value":{"placement":{"availabilityZone":"<NEW_ZONE>"}}}}}}}'
oc patch machineset $MS -n openshift-machine-api --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/providerSpec/value/subnet/filters/0/values/0","value":"<INFRA_ID>-subnet-private-<NEW_ZONE>"}]'
```

**GCP** uses a different path (`value.zone` instead of `value.placement.availabilityZone`).

Zone fallback only works within the same region. If all zones exhausted, destroy cluster and recreate in a different region.

## 4. A100 DynamicMIG on cloud VMs (GPU reset not supported)

A100 GPUs in cloud VM passthrough (GCP a2-highgpu, AWS p4d) do not support `nvidia-smi --gpu-reset`. MIG mode toggling requires a GPU reset, so every MIG mode change requires a **full node reboot**.

The DRA driver's `DestroyUnknownMIGDevices` startup code calls `SetMigMode(DISABLE)` on every restart, creating an unrecoverable loop.

**Automated workaround (setup handles this for A100 on GCP/AWS):**
1. Use patched DRA driver image (`quay.io/rh-pbhojara/nvidia-driver:v25.12.0-dev-patched`) that skips `DestroyUnknownMIGDevices`
2. Manually enable MIG via `nvidia-smi -i 0 -mig 1` through the GPU operator driver pod
3. Reboot the worker node (cordon, drain, reboot, uncordon)
4. Deploy a keepalive pod (1g.5gb MIG device) to prevent `maybeDisableMigMode` from triggering

**Checking MIG status:** `oc exec -n nvidia-gpu-operator <driver-pod> -- nvidia-smi --query-gpu=mig.mode.current,mig.mode.pending --format=csv`
- `Enabled, Enabled` = stable, ready for MIG workloads
- `Disabled, Enabled` = pending reboot to activate
- `Enabled, Disabled` = driver requested disable, needs reboot then re-enable

H100 supports GPU reset natively — no workaround needed.

## 5. Manual NFD node labeling

Automatic NFD detection can be slow or miss GPUs on fresh clusters. Scripts manually label nodes with `nvidia.com/gpu.present=true` as backup.

## 6. SCC grants required

OpenShift requires explicit Security Context Constraint grants for every NVIDIA service account. Missing grants cause pods to fail with permission denied.

## 7. GCP A2_CPUS quota fallback

Some GCP projects have `A2_CPUS=0` but a general `CPUS` quota that covers A2 instances. The quota check falls back to the general `CPUS` quota when the per-family quota is insufficient.

## 8. DynamicMIG=false for T4

T4 GPUs do not support MIG partitioning. The DRA driver will fail if DynamicMIG is enabled on non-MIG hardware. The script auto-gates this.

## 9. SharedCounterSets timing

With DynamicMIG, ResourceSlice may take up to 60s to update after MIG partition creation. Tests should wait for ResourceSlice to show the partition.
