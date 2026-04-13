# cluster-setup

Claude Code plugin marketplace for setting up OpenShift clusters with optional NVIDIA GPU and DRA support.

## Plugin Structure

This repo is a Claude Code plugin marketplace. The plugin lives in `plugins/cluster-setup/`.

## Commands (when installed as plugin)

- `/cluster-setup:setup` — Interactive cluster creation wizard
- `/cluster-setup:teardown` — Remove resources or destroy cluster
- `/cluster-setup:status` — Health check all components
- `/cluster-setup:test` — Run GPU/DRA smoke tests

## Local Development

Scripts are at `plugins/cluster-setup/bin/`. Run directly:

```bash
bash plugins/cluster-setup/bin/setup.sh --help
bash plugins/cluster-setup/bin/teardown.sh --cluster-name my-cluster
```

## Key Knowledge

- **SKILL.md**: `plugins/cluster-setup/skills/cluster-setup/SKILL.md` — quick-start and decision table
- **GPU Matrix**: `plugins/cluster-setup/skills/cluster-setup/references/gpu-matrix.md`
- **DRA Stack**: `plugins/cluster-setup/skills/cluster-setup/references/dra-stack.md`
- **Workarounds**: `plugins/cluster-setup/skills/cluster-setup/references/workarounds.md`
- **Error Recovery**: `plugins/cluster-setup/skills/cluster-setup/references/error-recovery.md`
