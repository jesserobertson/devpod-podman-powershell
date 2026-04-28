# devpod-provider-podman-windows

A [DevPod](https://devpod.sh) provider for [Podman](https://podman.io) on Windows, written in native PowerShell.

Uses Podman as a drop-in replacement for Docker to run DevPod workspaces locally. Manages the full Podman machine lifecycle: detection, auto-init, auto-start, and resource updates.

## Prerequisites

- [DevPod](https://devpod.sh/docs/getting-started/install) installed
- [Podman for Windows](https://github.com/containers/podman/releases) installed (`podman machine init` run at least once)
- PowerShell 7 (`pwsh`) in your PATH

## Install

```powershell
devpod provider add https://github.com/jesserobertson/devpod-podman-powershell/releases/download/v0.2.0/provider.yaml
```

## Usage

```powershell
devpod up https://github.com/microsoft/vscode-remote-try-python --provider podman-windows
```

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `PODMAN_PATH` | `podman` | Path to the podman binary. Falls back to `podman` on PATH. |
| `INACTIVITY_TIMEOUT` | _(none)_ | Auto-stop container after inactivity, e.g. `10m`, `1h`. |
| `PODMAN_MACHINE_AUTO_START` | `true` | Start the machine automatically if stopped. |
| `PODMAN_MACHINE_AUTO_INIT` | `false` | Create a machine automatically if none exists. |
| `PODMAN_MACHINE_NAME` | _(auto)_ | Machine name to use. Auto-detects if empty. |
| `PODMAN_MACHINE_START_TIMEOUT` | `60` | Seconds to wait for the machine to become ready. |
| `PODMAN_MACHINE_CPUS` | `2` | CPUs to allocate (used on init only). |
| `PODMAN_MACHINE_MEMORY` | `4096` | Memory in MB (used on init only). |
| `PODMAN_MACHINE_DISK_SIZE` | `100` | Disk in GB (used on init only). |
| `PODMAN_MACHINE_ROOTFUL` | `false` | Run machine in rootful mode. |
| `PODMAN_MACHINE_AUTO_RESOURCE_UPDATE` | `false` | Apply resource changes in-place via `podman machine set`. |

Set options after install:

```powershell
devpod provider set-options podman-windows PODMAN_MACHINE_CPUS=4 PODMAN_MACHINE_MEMORY=8192
```

If your existing machine differs from the defaults, set the options to match to silence the mismatch warnings:

```powershell
devpod provider set-options podman-windows PODMAN_MACHINE_CPUS=11 PODMAN_MACHINE_MEMORY=2048
```

## How it works

The provider is a small Go binary (`init_windows_amd64.exe`) that extracts and runs `init.ps1` via `pwsh -File`. The PowerShell script handles the full Podman machine lifecycle before DevPod takes over container management using Podman as its Docker-compatible runtime.

DevPod's `binaries` mechanism downloads and caches the binary at provider install time.

## Local development

Clone the repo and install directly from the local path:

```powershell
git clone https://github.com/jesserobertson/devpod-podman-powershell
cd devpod-podman-powershell
devpod provider add .
```

Edit `scripts/init.ps1` and test it standalone by setting the relevant env vars and running:

```powershell
$env:PODMAN_PATH = 'podman'
$env:PODMAN_MACHINE_AUTO_START = 'true'
$env:PODMAN_MACHINE_AUTO_INIT = 'false'
$env:PODMAN_MACHINE_START_TIMEOUT = '60'
$env:PODMAN_MACHINE_CPUS = '2'
$env:PODMAN_MACHINE_MEMORY = '4096'
$env:PODMAN_MACHINE_DISK_SIZE = '100'
$env:PODMAN_MACHINE_ROOTFUL = 'false'
$env:PODMAN_MACHINE_AUTO_RESOURCE_UPDATE = 'false'
pwsh -File scripts\init.ps1
```

## Releasing

Tag a new version to trigger the GitHub Actions release workflow, which builds the Go binary and uploads it alongside `init.ps1` and `provider.yaml`:

```bash
git tag v0.x.0
git push origin v0.x.0
```

After the workflow completes, copy the printed SHA256 into `provider.yaml` under `checksum:` and push.
