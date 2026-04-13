# Error Recovery

## Error Table

| Error | Cause | Fix |
|-------|-------|-----|
| Cluster create auth failure | Stale pull secret | Refresh at console.redhat.com |
| No worker node after 20 min | GPU stockout in zone | Auto zone fallback handles this; if all zones fail, try different region |
| Instance not found on provider | GCP instance vanished after creation | Auto retry — tries all zones twice |
| InsufficientInstanceCapacity | Regional capacity exhausted | Destroy cluster and recreate in different region |
| Cluster initialization timeout | No worker nodes available | Wait for worker to join; check machine status if stuck >5min |
| MCP Degraded | Feature gate conflict | Check `oc describe mcp`, may need to patch feature gates |
| GPU driver pod stuck in Init | Kernel module build failure | Delete pod, check driver toolkit image |
| No ResourceSlice | DRA driver permissions | Verify SCC grants for kubelet-plugin SA |
| nvidia-smi not found in pod | Wrong container image | Use CUDA-enabled image for GPU workloads |
| MIG mode "Not Supported" on A100 | Cloud VM GPU reset not supported | Use patched DRA driver image + manual MIG enable + node reboot |
| MIG Enabled/Disabled after reboot | Unpatched driver called SetMigMode(DISABLE) on startup | Switch to patched image, re-enable MIG, reboot again |
| onHostMaintenance MIGRATE rejected | GCP GPU instance needs Terminate | Set `onHostMaintenance: Terminate` in install-config or patch MachineSet |

## Resuming from a Failed Phase

DRA phases can be resumed with `--skip-to`:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/setup.sh \
  --cluster-name <name> \
  --cloud <cloud> \
  --gpu <gpu> \
  --dra \
  --pull-secret <path> \
  --install-dir /tmp/ocp-<name> \
  --skip-cluster \
  --skip-to <phase>
```

Valid phases: `feature-gates`, `cert-manager`, `nfd`, `gpu-operator`, `dra-driver`, `smoke-test`

`--skip-to` a DRA phase automatically implies `--dra`.

## On Script Failure

If setup.sh fails after cluster creation, it displays:
- The cluster may still be running (costs money)
- Command to destroy: `/cluster-setup:teardown`
- Command to resume from where it left off

## Environment Variables

| Var | Default | Description |
|-----|---------|-------------|
| `KUBECONFIG` | (from install dir) | Path to cluster kubeconfig |
| `OPENSHIFT_INSTALL` | (auto-resolved) | Path to openshift-install binary |
| `GCP_PROJECT` | (required for GCP) | GCP project ID |
| `GCP_BASE_DOMAIN` | `gcp.devcluster.openshift.com` | GCP base domain |
| `AWS_BASE_DOMAIN` | `devcluster.openshift.com` | AWS base domain |
| `OCP_VERSION` | `4.21.0` | OpenShift version |
