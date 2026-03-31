# Cluster Teardown

Help the user tear down their GPU test cluster.

## Ask the user:
1. **Resources only** or **full cluster destroy**?
   - Resources only: removes GPU operator, DRA driver, NFD but keeps the cluster
   - Full destroy: removes everything and destroys the OpenShift cluster
2. **Cluster name** or **install directory** to locate the cluster

## Run teardown

```bash
# Resources only
bash bin/teardown.sh --resources-only --cluster-name <name>

# Full destroy
bash bin/teardown.sh --cluster-name <name>
```

Confirm before running — this is destructive and irreversible for cluster destroy.
