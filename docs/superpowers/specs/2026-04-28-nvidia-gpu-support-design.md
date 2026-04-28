# NVIDIA GPU Support Design

**Date:** 2026-04-28  
**Status:** Revised — cloud-init not supported on WSL2 backend; switched to SSH post-setup

## Overview

Add opt-in NVIDIA GPU support to the `podman-windows` DevPod provider. When `PODMAN_MACHINE_NVIDIA_GPU=true`, `init.ps1` SSHs into the running machine after startup and idempotently installs the NVIDIA Container Toolkit and generates CDI specs, making `nvidia.com/gpu=all` resolvable inside containers.

## Goals

- `devcontainer.json` `runArgs: ["--gpus", "all"]` works without manual post-init steps
- Works for both newly created and already-existing machines
- Idempotent — skips setup if CDI specs already present
- CDI specs survive machine restarts (nvidia-container-toolkit installs a `nvidia-cdi-refresh` systemd service that regenerates specs on boot)
- Zero impact on users who don't set the GPU option

## Non-Goals

- Supporting non-WSL2 Podman Machine backends
- Supporting GPUs other than NVIDIA

## Why Not Cloud-Init

`podman machine init` on the WSL2 backend does not support `--user-data`. The available flags are `--ignition-path` and `--playbook`, but SSH post-setup is simpler, more portable, and handles existing machines without recreation.

## Changes

### `provider.yaml`

Update description of `PODMAN_MACHINE_NVIDIA_GPU` (option already present):

```yaml
PODMAN_MACHINE_NVIDIA_GPU:
  description: >
    After the machine starts, install the NVIDIA Container Toolkit via SSH
    and generate CDI specs if not already present. Enables --gpus all in
    devcontainers. Works on both new and existing machines.
  default: "false"
```

### `scripts/init.ps1`

Remove the cloud-init injection block from step 4. Add a new step after the machine is confirmed running (after step 5's readiness loop, or step 6's resource update — wherever execution reaches a confirmed-running state):

```powershell
# ── 6b. NVIDIA GPU setup (SSH) ────────────────────────────────────────────────
if ($env:PODMAN_MACHINE_NVIDIA_GPU -eq 'true') {
    Write-Host "Checking NVIDIA CDI specs on '$machineName'..."
    $cdiStatus = & $podmanExe machine ssh $machineName `
        "test -f /etc/cdi/nvidia.yaml && echo exists || echo missing" 2>&1
    if ($cdiStatus -notmatch 'exists') {
        Write-Host "CDI specs not found. Installing NVIDIA Container Toolkit (this may take a few minutes)..."
        & $podmanExe machine ssh $machineName @'
sudo curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
  -o /etc/yum.repos.d/nvidia-container-toolkit.repo \
&& sudo dnf install -y nvidia-container-toolkit \
&& sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
'@
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to install NVIDIA Container Toolkit on '$machineName'."
            exit 1
        }
        Write-Host "NVIDIA Container Toolkit installed and CDI specs generated."
    }
    else {
        Write-Host "CDI specs already present on '$machineName', skipping NVIDIA setup."
    }
}
```

Remove the `$userDataFile` block and the warning block from step 4.

### `tests/init.Tests.ps1`

Replace the two existing GPU test contexts (`no machine, AUTO_INIT=true, NVIDIA_GPU=true` and `existing machine, NVIDIA_GPU=true`) with:

1. **`existing machine running, NVIDIA_GPU=true, CDI missing`** — SSH setup runs, exits 0
2. **`existing machine running, NVIDIA_GPU=true, CDI present`** — SSH setup skipped, exits 0

### Mocks

- Remove `tests/mocks/podman-no-machine-gpu.ps1` (no longer needed)
- Update `tests/mocks/podman-running.ps1` to handle `machine ssh <name> "..."`:
  - Default: return `exists` (CDI present)
- Add `tests/mocks/podman-running-no-cdi.ps1`: identical to `podman-running.ps1` but `machine ssh` returns `missing`

### `README.md`

Update GPU support section: remove the "recreate required" note, update workflow to show it works on existing machines.

## Workflow

```powershell
devpod provider set-options podman-windows -o PODMAN_MACHINE_NVIDIA_GPU=true
devpod up .   # init.ps1 SSHs in, installs toolkit if missing, CDI specs generated
```

On subsequent `devpod up` calls, CDI specs are already present — setup is skipped in ~1 second.

## Key Design Decisions

- **SSH post-setup over `--ignition-path`/`--playbook`:** SSH is portable, debuggable, works on existing machines, and requires no knowledge of Ignition or Ansible. The machine is already running when this step fires, so SSH is always available.
- **Idempotent check:** `test -f /etc/cdi/nvidia.yaml` before running the install means repeated `devpod up` calls skip the slow DNF install entirely.
- **nvidia-cdi-refresh systemd service:** The toolkit package installs this service, which regenerates CDI specs on every boot — so specs survive machine restarts without any provider involvement.
