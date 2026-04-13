# Separate GPU Hardware from DRA Stack

## Problem

Currently `--gpu <type>` in `setup.sh` implies the full DRA stack (feature gates, cert-manager, NFD, GPU Operator, DRA Driver, smoke test). There is no way to provision a cluster with GPU hardware without also installing the DRA stack.

This causes two issues:

1. **The DRA stack only works on OCP 4.21+ (K8s 1.34+)** where `resource.k8s.io/v1` is GA. The current code hardcodes `resource.k8s.io/v1` in the keepalive ResourceClaim and uses feature gates (`DRAResourceClaimDeviceStatus`, `DRAExtendedResource`) that don't exist in older versions. Running the stack on older OCP versions will fail.

2. **Users who want GPU hardware without DRA have no clean path.** The `/setup` skill previously tried `--gpu t4 --no-gpu` (contradictory) or ran all 8 phases unconditionally.

## Version Matrix (from Kubernetes docs)

| OCP  | K8s  | ResourceClaim API | DRA Stage |
|------|------|-------------------|-----------|
| 4.18 | 1.31 | `v1alpha3`        | Alpha     |
| 4.19 | 1.32 | `v1beta1`         | Beta      |
| 4.20 | 1.33 | `v1beta2`         | Beta      |
| 4.21 | 1.34 | `v1`              | GA        |

Feature gates that the current code applies:

| Gate                           | Introduced | Exists in 4.21 (1.34)? |
|--------------------------------|------------|------------------------|
| `DynamicResourceAllocation`    | 1.26 alpha | GA, locked on          |
| `DRAResourceClaimDeviceStatus` | 1.32 alpha | Beta, on by default    |
| `DRAExtendedResource`          | 1.34 alpha | Alpha, off by default  |
| `DRAPartitionableDevices`      | 1.33 alpha | Alpha, off by default  |

The current helm chart versions (GPU Operator v25.x, DRA Driver 25.x) target K8s 1.34+ / OCP 4.21+.

## Design

### New flag: `--dra`

Separate "GPU hardware provisioning" from "DRA stack installation":

- `--gpu <type>` provisions the cluster with the correct GPU instance type, does MachineSet patching (T4), sets `onHostMaintenance: Terminate` (GCP), etc. Stops after cluster creation.
- `--dra` (new, opt-in) installs the DRA stack on top: feature gates, cert-manager, NFD, GPU Operator, DRA Driver, smoke test.
- `--dra` requires `--gpu` (or a GPU-capable `--instance-type`). Error if used with `--no-gpu` or non-GPU instance.
- `--dra` requires OCP >= 4.21. Error with clear message if OCP version is too old.

### Phase execution changes in `setup.sh`

Current phases when GPU is selected:
1. Quota check + cluster creation (always)
2. Feature gates (GPU only)
3. cert-manager (GPU only)
4. NFD (GPU only)
5. GPU Operator (GPU only)
6. DRA Driver (GPU only)
7. Smoke test (GPU only)

New behavior:

| Flag combo              | Phases that run        |
|-------------------------|------------------------|
| `--gpu t4`              | 1 (cluster + GPU HW)  |
| `--gpu t4 --dra`        | 1-7 (full DRA stack)   |
| `--instance-type m6i.xlarge` | 1 (cluster, no GPU) |
| `--no-gpu`              | 1 (cluster, no GPU)    |

The `has_gpu` helper remains for cluster creation (instance type, MachineSet patching). A new `has_dra` helper gates phases 2-7.

### OCP version check

In `setup.sh` arg validation, after resolving `OCP_VERSION`:

```bash
# Parse OCP minor version: "4.21.0" -> 21
ocp_minor="${OCP_VERSION#4.}"
ocp_minor="${ocp_minor%%.*}"

if [[ "$DRA" == "true" ]]; then
    if (( ocp_minor < 21 )); then
        log_error "DRA stack requires OCP 4.21+ (K8s 1.34+). Selected version: ${OCP_VERSION}"
        log_error "Remove --dra to provision the cluster with GPU hardware only."
        exit 1
    fi
fi
```

### `/setup` skill changes

The interactive wizard:
1. Asks for cloud, instance type / GPU, OCP version (as today)
2. **New step:** If GPU is selected **and** OCP >= 4.21, asks: "Install the NVIDIA DRA stack (GPU Operator + DRA Driver)?"
3. If user says yes: passes `--dra` to `setup.sh`
4. If user says no, or OCP < 4.21: omits `--dra`

### `--smoke-test` interaction

`--smoke-test` checks DRA resources (DeviceClass, ResourceSlice). It only makes sense with `--dra`. If `--smoke-test` is passed without `--dra`, warn and skip (same pattern as current `--smoke-test` without `--gpu`).

### `--skip-to` interaction

`--skip-to` for DRA phases (feature-gates, cert-manager, nfd, gpu-operator, dra-driver, smoke-test) implies `--dra`. If OCP < 4.21 with `--skip-to` a DRA phase, error out.

### Summary block changes

The setup summary reflects the new state:

```
  GPU:           t4 (n1-standard-8 + nvidia-tesla-t4 accelerator)
  DRA Stack:     yes (feature gates, cert-manager, NFD, GPU Operator, DRA Driver)
```

or:

```
  GPU:           t4 (n1-standard-8 + nvidia-tesla-t4 accelerator)
  DRA Stack:     no
```

### Files changed

| File | Change |
|------|--------|
| `bin/setup.sh` | Add `--dra` flag, `has_dra` helper, version check, gate phases 2-7 on `has_dra` |
| `bin/setup.sh` | Update usage text, summary block |
| `CLAUDE.md` | Document `--dra` flag, update phase table |
| `/setup` skill | Add DRA prompt when GPU + OCP >= 4.21 |

### Files NOT changed

- `bin/lib/config.sh` — no changes, feature gates and helm versions stay as-is
- `bin/lib/features.sh` — no changes, only called when `--dra` is active
- `bin/lib/dra-driver.sh` — no changes, only called when `--dra` is active
- Other lib files — untouched

## What this does NOT do

- No multi-version API support (v1alpha3, v1beta1, v1beta2). The DRA stack targets OCP 4.21+ only.
- No legacy device plugin fallback. Users on older OCP can install GPU Operator manually.
- No changes to the DRA stack itself (feature gates, helm values, ResourceClaim API version all stay as-is for v1/4.21+).
