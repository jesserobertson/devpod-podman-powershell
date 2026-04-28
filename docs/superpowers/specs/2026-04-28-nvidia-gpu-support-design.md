# NVIDIA GPU Support Design

**Date:** 2026-04-28
**Status:** Approved

## Overview

Add opt-in NVIDIA GPU support to the `podman-windows` DevPod provider. When a new Podman Machine is created with `PODMAN_MACHINE_NVIDIA_GPU=true`, the machine is initialised with a cloud-init user-data file that installs the NVIDIA Container Toolkit and generates CDI specs, making `nvidia.com/gpu=all` resolvable inside containers.

## Goals

- `devcontainer.json` `runArgs: ["--gpus", "all"]` works without manual post-init steps
- CDI specs persist across `podman machine stop/start` (WSL2 filesystem is persistent)
- Zero impact on users who don't set the GPU option
- Existing machines are not modified; users recreate at their own discretion

## Non-Goals

- Repairing GPU support on existing machines (cloud-init only fires on first boot)
- Supporting non-WSL2 Podman Machine backends
- Supporting GPUs other than NVIDIA

## Changes

### `provider.yaml`

Add one option to the "Machine Management" group:

```yaml
PODMAN_MACHINE_NVIDIA_GPU:
  description: >
    Pass a cloud-init user-data file to the machine on init that installs
    the NVIDIA Container Toolkit and generates CDI specs. Requires
    PODMAN_MACHINE_AUTO_INIT=true. Has no effect on already-existing machines.
  default: "false"
```

### `scripts/init.ps1`

In the machine init block (step 4), when `PODMAN_MACHINE_NVIDIA_GPU=true`:

1. Write the cloud-init YAML (below) to `$env:TEMP\podman-nvidia-userdata.yaml`
2. Append `--user-data <tempfile>` to `$initArgs`
3. Delete the temp file after `podman machine init` completes (success or failure)

Cloud-init content (Fedora-based Podman Machine image uses `dnf`):

```yaml
#cloud-config
runcmd:
  - curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo -o /etc/yum.repos.d/nvidia-container-toolkit.repo
  - dnf install -y nvidia-container-toolkit
  - nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
```

When `PODMAN_MACHINE_NVIDIA_GPU=true` but `PODMAN_MACHINE_AUTO_INIT=false` (machine already exists), emit `Write-Warning` and continue — no error, no behaviour change.

### `README.md`

Add a "GPU support" section:

- Set `PODMAN_MACHINE_NVIDIA_GPU=true` alongside `PODMAN_MACHINE_AUTO_INIT=true` before the machine is created
- If a machine already exists, remove it first: `podman machine rm <name>`
- Verify GPU access after the machine starts: `podman run --rm --device nvidia.com/gpu=all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi`

## Workflow

```
devpod provider set-options podman-windows \
  PODMAN_MACHINE_AUTO_INIT=true \
  PODMAN_MACHINE_NVIDIA_GPU=true

devpod up .   # machine is created with cloud-init, CDI specs generated
```

On subsequent `devpod up` calls the machine is already running; the GPU option is silently ignored (specs persist on the WSL2 filesystem).

## Key Design Decisions

- **Cloud-init only (no SSH post-setup):** The WSL2 filesystem persists across machine restarts, so one-time setup at machine creation is sufficient. Recreating a machine is fast enough that a "repair existing machine" path adds complexity without proportionate benefit.
- **Embedded here-string:** The cloud-init YAML is written inline in `init.ps1` rather than shipped as a separate file, keeping the provider self-contained (the Go binary wraps only `init.ps1`).
- **Warn, don't error, on existing machines:** Failing hard when the machine already exists would break `devpod up` for users who set the option after machine creation. A warning is more helpful.
