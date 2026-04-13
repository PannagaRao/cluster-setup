# Cluster Teardown

Help the user tear down their cluster.

## Ask the user:
1. **Resources only** or **full cluster destroy**?
   - Resources only: removes GPU operator, DRA driver, NFD (if installed) but keeps the cluster
   - Full destroy: removes everything and destroys the OpenShift cluster
2. **Cluster name** or **install directory** to locate the cluster

Note: The teardown script automatically detects whether GPU/DRA resources were installed. If no GPU resources are found (e.g. non-GPU cluster), it skips resource cleanup and proceeds directly to cluster destroy.

## Run teardown

```bash
# Resources only (skips if no GPU resources found)
bash bin/teardown.sh --resources-only --cluster-name <name>

# Full destroy
bash bin/teardown.sh --cluster-name <name>
```

Confirm before running -- this is destructive and irreversible for cluster destroy.
