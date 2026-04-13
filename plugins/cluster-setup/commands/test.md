# GPU/DRA Smoke Test

Run tests to verify the GPU cluster is working with DRA.

## Smoke Test
Submit a GPU job and verify it runs with GPU access via DRA:
```bash
# Check DRA resources exist
oc get deviceclass
oc get resourceslice

# Run a simple GPU test pod
oc run gpu-test --image=nvcr.io/nvidia/cuda:12.6.3-base-ubi9 --restart=Never -- nvidia-smi
oc wait --for=condition=Ready pod/gpu-test --timeout=120s
oc logs gpu-test
oc delete pod gpu-test
```

## MIG Test (only for A100/H100 with DynamicMIG)
If the cluster has MIG-capable GPUs with DynamicMIG enabled:
1. Create ResourceClaimTemplates requesting specific MIG profiles (1g, 2g, etc.)
2. Submit pods requesting each profile
3. Verify both pods run on the same GPU with different MIG slices
4. Check ResourceSlice for MIG partition attributes

Report results and clean up test resources.
