# Cluster Teardown

Help the user tear down their cluster.

## Gather info

Ask for the **cluster name** or **install directory** to locate the cluster.

If both are unknown, check for recent install directories:
```bash
ls -dt /tmp/ocp-* 2>/dev/null | head -5
```

## Determine teardown scope

Check if the cluster has DRA resources installed:
```bash
oc get namespace nvidia-dra-driver-gpu nvidia-gpu-operator node-feature-discovery 2>/dev/null
```

**If DRA resources exist:** Ask the user — "Remove just the DRA stack, or destroy the entire cluster?"
- DRA stack only: `bash ${CLAUDE_PLUGIN_ROOT}/bin/teardown.sh --resources-only --cluster-name <name>`
- Full destroy: `bash ${CLAUDE_PLUGIN_ROOT}/bin/teardown.sh --cluster-name <name>`

**If no DRA resources:** Skip the question, go straight to full destroy:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/bin/teardown.sh --cluster-name <name>
```

## Run teardown

No additional confirmation needed — the user already asked to teardown. Just run it.

Monitor the output. Cluster destruction typically takes 10-20 minutes.
