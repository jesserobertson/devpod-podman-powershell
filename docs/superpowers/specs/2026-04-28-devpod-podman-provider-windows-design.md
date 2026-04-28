# DevPod Podman Provider for Windows — Design

**Date:** 2026-04-28  
**Status:** Approved

## Problem

No official DevPod Podman provider exists (loft-sh issue #1919 closed as stale). Community providers (kuju63, ThomasVitale) are bash-only and handle macOS machine management. Windows users with the standalone podman-for-windows installer have no working provider.

## Approach

Option B: separate `.ps1` script files distributed as provider artifacts via the DevPod `binaries` mechanism. The `provider.yaml` downloads `init.ps1` from GitHub releases and calls it via `pwsh`. Scripts are 100% native PowerShell with no YAML-escaping overhead.

Alternatives considered:
- **Inline PowerShell via pwsh wrapper** — single file but unmaintainable at 200+ lines of embedded PS in YAML
- **Go binary** — most portable but overkill for a personal Windows tool

## Architecture

```
devpod-podman-powershell/
├── provider.yaml              # DevPod provider config
├── scripts/
│   └── init.ps1               # Machine lifecycle logic
├── .github/
│   └── workflows/
│       └── release.yml        # Computes checksum, uploads init.ps1 as release artifact
└── docs/superpowers/specs/
```

**Runtime flow:**
1. `devpod provider add <url>` — DevPod fetches `provider.yaml`, downloads `init.ps1` from the GitHub release into its local cache, exposes path as `${INIT_SCRIPT}`
2. `devpod up <workspace>` — DevPod calls `exec.init` → `pwsh -NonInteractive -NoProfile -File "${INIT_SCRIPT}"`
3. DevPod uses `agent.docker.path = ${PODMAN_PATH}` to drive container creation via Podman as the Docker CLI replacement; agent runs locally (no SSH into a VM)
4. `exec.command` delegates to `"${DEVPOD}" helper sh -c "${COMMAND}"` — DevPod substitutes variables before the shell sees them

## `provider.yaml` Structure

```yaml
name: podman-windows
version: v0.1.0
description: DevPod on Podman for Windows (PowerShell)
home: https://github.com/robejess/devpod-podman-powershell

options:
  PODMAN_PATH:
    description: Path to the podman binary.
    default: podman
  INACTIVITY_TIMEOUT:
    description: "Auto-stop container after inactivity. Examples: 10m, 1h"
  PODMAN_MACHINE_AUTO_START:
    description: Automatically start the Podman machine if stopped.
    default: "true"
  PODMAN_MACHINE_AUTO_INIT:
    description: Automatically initialize a Podman machine if none exists.
    default: "false"
  PODMAN_MACHINE_NAME:
    description: Name of the Podman machine. Auto-detects if empty.
  PODMAN_MACHINE_START_TIMEOUT:
    description: Seconds to wait for machine to start.
    default: "60"
  PODMAN_MACHINE_CPUS:
    description: CPUs to allocate (used on init only).
    default: "2"
  PODMAN_MACHINE_MEMORY:
    description: Memory in MB (used on init only).
    default: "4096"
  PODMAN_MACHINE_DISK_SIZE:
    description: Disk size in GB (used on init only).
    default: "100"
  PODMAN_MACHINE_ROOTFUL:
    description: Run machine in rootful mode.
    default: "false"
  PODMAN_MACHINE_AUTO_RESOURCE_UPDATE:
    description: Apply resource changes in-place without recreating the machine.
    default: "false"

agent:
  containerInactivityTimeout: ${INACTIVITY_TIMEOUT}
  local: true
  docker:
    path: ${PODMAN_PATH}
    install: false

binaries:
  INIT_SCRIPT:
    - os: windows
      arch: amd64
      path: https://github.com/robejess/devpod-podman-powershell/releases/download/v0.1.0/init.ps1
      checksum: ""   # filled in by release workflow

exec:
  init: pwsh -NonInteractive -NoProfile -File "${INIT_SCRIPT}"
  command: '"${DEVPOD}" helper sh -c "${COMMAND}"'
```

## `init.ps1` Logic

PowerShell port of kuju63's macOS bash init script. No OS guard needed — Windows always requires `podman machine`.

**Step 1 — Resolve binary:**
```powershell
$podman = Get-Command $env:PODMAN_PATH -ErrorAction SilentlyContinue
if (-not $podman) { $podman = Get-Command podman -ErrorAction SilentlyContinue }
if (-not $podman) { Write-Error "Podman not found..."; exit 1 }
$podmanExe = $podman.Source
```

**Step 2 — Print version:** `& $podmanExe --version`

**Step 3 — Resolve machine name:**
- Use `$env:PODMAN_MACHINE_NAME` if set
- Otherwise auto-detect: `(& $podmanExe machine list --format json) | ConvertFrom-Json | Select-Object -First 1`

**Step 4 — Machine existence:**
- No machine + `AUTO_INIT=true` → `podman machine init` with configured CPUs/memory/disk/rootful flags
- No machine + `AUTO_INIT=false` → `Write-Error` with manual fix instructions, `exit 1`

**Step 5 — Machine state** (from `podman machine inspect <name> | ConvertFrom-Json`):
- Not running + `AUTO_START=true` → `podman machine start`, poll `podman ps` until ready or timeout
- Not running + `AUTO_START=false` → error with manual fix, `exit 1`

**Step 6 — Resource mismatch** (only when machine already running):
- Compare CPUs/Memory/DiskSize/Rootful from inspect JSON against env var options
- `AUTO_RESOURCE_UPDATE=true` → stop, apply `podman machine set` changes, restart, verify
- `AUTO_RESOURCE_UPDATE=false` → print warning table showing current vs desired, suggest commands, continue
- Disk shrink always rejected (Podman constraint)

**Step 7 — Connectivity check:** `& $podmanExe ps` must exit 0

**PowerShell advantages over bash:**
- `ConvertFrom-Json` parses `podman machine inspect` output — no grep/awk
- `$ErrorActionPreference = 'Stop'` for unexpected errors
- `-ErrorAction SilentlyContinue` for optional checks

## Development Workflow

**Local dev** (before releases are set up):

DevPod has no provider override mechanism — `devpod provider add <local-dir>` reads `provider.yaml` from that directory directly. During development:

1. Remove the `binaries` section from `provider.yaml` and replace `exec.init` with a hardcoded local path:
```yaml
exec:
  init: pwsh -NonInteractive -NoProfile -File "C:\Users\robejess\Developer\devpod-podman-powershell\scripts\init.ps1"
```
2. Install with: `devpod provider add C:\Users\robejess\Developer\devpod-podman-powershell`
3. Restore `binaries` section and parameterised `exec.init` before tagging a release.

For script-only iteration (no DevPod needed), set env vars in PowerShell and call `pwsh -File scripts\init.ps1` directly.

**Release process:**

GitHub Actions on tag push:
1. Computes SHA256 of `scripts/init.ps1`
2. Uploads `init.ps1` as release artifact
3. Outputs checksum to paste into `provider.yaml` binaries section

Install for others: `devpod provider add https://raw.githubusercontent.com/robejess/devpod-podman-powershell/v0.1.0/provider.yaml`

## Testing Checklist

- [ ] No machine, `AUTO_INIT=false` → clear error message
- [ ] No machine, `AUTO_INIT=true` → machine created and started
- [ ] Machine stopped, `AUTO_START=true` → machine started
- [ ] Machine running, resource mismatch, `AUTO_RESOURCE_UPDATE=false` → warning printed, continues
- [ ] Machine running, resource mismatch, `AUTO_RESOURCE_UPDATE=true` → resources updated in-place
- [ ] Disk shrink attempted → rejected with clear error
- [ ] `devpod up` end-to-end with a simple repo
