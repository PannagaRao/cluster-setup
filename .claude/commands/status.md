# Cluster Status Check

Run a health check on the current GPU test cluster.

Set KUBECONFIG if needed, then run:
```bash
bash bin/status.sh
```

Present the results in a clear format. If any component is unhealthy, suggest the fix:
- Missing cert-manager: `--skip-to cert-manager`
- Missing NFD: `--skip-to nfd`
- Missing GPU operator: `--skip-to gpu-operator`
- Missing DRA driver: `--skip-to dra-driver`
- MCP Degraded: check `oc describe mcp` for the reason
