# DRA Example Driver

Simulated DRA devices for testing without GPU hardware. From `kubernetes-sigs/dra-example-driver`.

## What It Does

Creates virtual GPU devices with configurable partitions, exposed via the `gpu.example.com` DeviceClass. No GPU hardware needed.

## Parameters

| Flag | Default | Description |
|------|---------|-------------|
| `--dra-example-driver` | — | Enable example driver (mutually exclusive with `--gpu`/`--dra`) |
| `--dra-example-version` | `v0.3.0` | Driver version |
| `--dra-example-devices` | `8` | Simulated GPUs per node |
| `--dra-example-partitions` | `4` | Partitions per GPU (0 = disabled) |

## What Gets Created

- **DeviceClass**: `gpu.example.com`
- **ResourceSlices**: 2 per node
- **Devices per GPU** (with 4 partitions):
  - `gpu-N-partition-0` through `gpu-N-partition-3` (20Gi each)
  - `gpu-N-full` (80Gi) — full GPU
- **Total** (8 GPUs x 4 partitions): 40 devices (32 partitions + 8 full)

## Device Attributes

```yaml
attributes:
  driverVersion: {version: "1.0.0"}
  index: {int: N}
  model: {string: "LATEST-GPU-MODEL"}
  partition: {int: N}          # absent for full GPU
  partitionable: {bool: true}
capacity:
  memory: {value: "20Gi"}     # 20Gi per partition, 80Gi for full
```

## Differences from NVIDIA DRA Driver

| | NVIDIA DRA Driver | DRA Example Driver |
|---|---|---|
| Hardware | Requires GPU | No hardware needed |
| Chart source | Helm repo | Source tarball |
| Namespace | `nvidia-dra-driver-gpu` | `dra-example-driver` |
| DeviceClass | `gpu.nvidia.com`, `mig.nvidia.com` | `gpu.example.com` |
| Partitioning | MIG profiles (1g.5gb etc.) | Generic partitions (configurable count) |
| GPU Operator | Required | Not needed |
| Node reboot | A100 MIG requires reboot | Never |
| Use case | Production GPU workloads | Testing DRA/Kueue without GPUs |

## Namespace and SCC

```bash
oc create namespace dra-example-driver
oc adm policy add-scc-to-user privileged -z dra-example-driver-service-account -n dra-example-driver
```

## CI Reference

Used in Kueue CI: `ci-operator/step-registry/dra-example-driver/install/`
