# DRA Stack Details

## Version Compatibility

The DRA stack requires OCP 4.21+ (K8s 1.34+). The `--dra` flag enforces this.

| OCP  | K8s  | ResourceClaim API | DRA Stage |
|------|------|-------------------|-----------|
| 4.18 | 1.31 | `v1alpha3`        | Alpha     |
| 4.19 | 1.32 | `v1beta1`         | Beta      |
| 4.20 | 1.33 | `v1beta2`         | Beta      |
| 4.21 | 1.34 | `v1`              | GA        |

## Feature Gates Applied (OCP 4.21)

| Gate | Status in K8s 1.34 |
|------|-------------------|
| `DynamicResourceAllocation` | GA, locked on |
| `DRAResourceClaimDeviceStatus` | Beta, on by default |
| `DRAExtendedResource` | Alpha, off by default |
| `DRAPartitionableDevices` | Alpha, off by default (added for dynamicmig) |

The feature gate patch uses `customNoUpgrade.enabled` on the cluster featuregate resource. The script auto-detects the field format (string vs object) via `oc explain`.

## Helm Chart Versions

| Component | Chart Name | Chart Version | Env Override |
|-----------|-----------|--------------|-------------|
| NFD | — | 0.17.3 | `--nfd-version` |
| GPU Operator | `nvidia/gpu-operator` | v25.10.1 | `--gpu-operator-version` |
| DRA Driver | `nvidia/dra-driver-nvidia-gpu` | 0.4.0 | `--dra-driver-version` |

The DRA driver moved from `nvidia/nvidia-dra-driver-gpu` (v25.x) to `nvidia/dra-driver-nvidia-gpu` (v0.4.0+) when the project moved to `kubernetes-sigs/dra-driver-nvidia-gpu`.

Container image: `registry.k8s.io/dra-driver-nvidia/dra-driver-nvidia-gpu`

## DRA Stack Phases (in order)

1. **Feature gates** — enable DRA feature gates, wait for MCP rollout
2. **cert-manager** — install cert-manager operator
3. **NFD** — Node Feature Discovery + manual GPU labeling
4. **GPU Operator** — NVIDIA GPU Operator with DRA enabled, device plugin DISABLED
5. **DRA Driver** — NVIDIA DRA Driver (MIG mode auto-gated by GPU type)
6. **Smoke test** — verify DeviceClass and ResourceSlice exist (optional, `--smoke-test`)

## Key Namespaces

- `cert-manager` — cert-manager operator
- `node-feature-discovery` — NFD
- `nvidia-gpu-operator` — GPU Operator + driver
- `nvidia-dra-driver-gpu` — DRA driver (controller + kubelet-plugin)

## Critical: devicePlugin.enabled=false

The GPU Operator MUST have `devicePlugin.enabled=false` when using DRA. If left true, the standard device plugin conflicts with the DRA driver.
