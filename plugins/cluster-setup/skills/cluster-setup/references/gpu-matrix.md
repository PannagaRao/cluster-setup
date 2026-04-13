# GPU Instance Matrix

## Instance Types

| GPU  | GCP Instance      | AWS Instance    | GPUs | MIG | vCPUs |
|------|-------------------|-----------------|------|-----|-------|
| T4   | n1-standard-8 + nvidia-tesla-t4 accelerator | g4dn.xlarge | 1 | No | 8/4 |
| L4   | g2-standard-8     | (GCP only)      | 1    | No  | 8 |
| A100 | a2-highgpu-1g     | p4d.24xlarge    | 1/8  | Yes | 12/96 |
| H100 | a3-highgpu-1g     | p5.4xlarge      | 1    | Yes | 26/16 |

## Non-GPU Defaults

| Cloud | Instance | vCPUs | Memory |
|-------|----------|-------|--------|
| AWS | m6i.xlarge | 4 | 16 GB |
| GCP | n2-standard-4 | 4 | 16 GB |

## Zone Priorities (fallback order)

| Cloud-GPU | Primary Zones | Fallback Zones |
|-----------|--------------|----------------|
| GCP T4 | us-east1-b, c, d | us-central1-a, b, c |
| GCP L4 | us-east1-b, c, d | us-central1-a, b, c + us-west1 |
| GCP A100 | us-central1-f, a, b, c | us-east1-b, c, d |
| GCP H100 | us-east1-b, c, d | us-central1-a, b, c |
| GCP none | us-east1-b, c, d | — |
| AWS T4/A100/H100 | ap-south-1a, b, c | us-east-1a, b, c |

Note: `us-east1-a` does not exist on GCP.

## Quota Status (GCP project: openshift-gce-devel)

**GCP:**
- T4: 16 GPUs quota in us-central1 — works
- A100: 10 GPUs quota, A2_CPUS=0 but general CPUS=1000 covers it — works
- H100: No quota — needs quota request

**AWS:**
- T4: 920 G-instance vCPUs — works
- A100: 692 P-instance vCPUs — works
- H100: 692 P-instance vCPUs — works

## H100 Strategy

When H100 is requested and GCP quota check fails:
1. Suggest AWS instead — AWS p5.48xlarge is more readily available
2. Check zone availability: `aws ec2 describe-instance-type-offerings --filters "Name=instance-type,Values=p5.48xlarge" --region <REGION>`

## MIG Capability

- T4, L4: No MIG support. `--mig-mode dynamicmig` auto-falls back to timeslicing.
- A100, H100: MIG supported. Can use `timeslicing` (default) or `dynamicmig`.
