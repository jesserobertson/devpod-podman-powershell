# DevPod Podman Provider for Windows — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native PowerShell DevPod provider that manages a Podman machine on Windows and lets DevPod use Podman as its container runtime.

**Architecture:** `provider.yaml` declares options, an agent config pointing at the Podman binary, and an `exec.init` that calls `scripts/init.ps1` via `pwsh`. During local development `provider.yaml` hardcodes the local script path; for releases the `binaries` section downloads `init.ps1` from GitHub and exposes it as `${INIT_SCRIPT}`. The init script handles the full Podman machine lifecycle: binary resolution, machine detection, auto-init, auto-start, resource mismatch detection, and connectivity verification.

**Tech Stack:** PowerShell 7 (`pwsh`), `podman` CLI (podman-for-windows), DevPod provider YAML spec, GitHub Actions

---

## File Map

| File | Purpose |
|------|---------|
| `provider.yaml` | DevPod provider config — options, agent, binaries, exec |
| `scripts/init.ps1` | Machine lifecycle — full init logic in PowerShell |
| `.github/workflows/release.yml` | On tag: compute SHA256, upload `init.ps1` as release artifact |
| `.gitignore` | Exclude test artefacts |

---

## Task 1: Project scaffold

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Create `.gitignore`**

```
# PowerShell test artefacts
*.ps1xml
# Local DevPod test state
.devpod/
```

Save to `.gitignore` at the repo root.

- [ ] **Step 2: Create the scripts directory placeholder**

The `scripts/` directory needs to exist in git. Create an empty `scripts/.gitkeep`:

```
(empty file)
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore scripts/.gitkeep
git commit -m "chore: project scaffold"
```

---

## Task 2: `provider.yaml` (dev version)

**Files:**
- Create: `provider.yaml`

This is the development version — no `binaries` section, `exec.init` hardcodes the local script path. You will swap in the `binaries` block in Task 10 before releasing.

- [ ] **Step 1: Create `provider.yaml`**

```yaml
name: podman-windows
version: v0.1.0
description: DevPod on Podman for Windows (PowerShell)
home: https://github.com/robejess/devpod-podman-powershell

optionGroups:
  - name: "Basic Options"
    options:
      - PODMAN_PATH
      - INACTIVITY_TIMEOUT
  - name: "Machine Management"
    options:
      - PODMAN_MACHINE_AUTO_START
      - PODMAN_MACHINE_AUTO_INIT
      - PODMAN_MACHINE_NAME
      - PODMAN_MACHINE_START_TIMEOUT
  - name: "Machine Resources"
    options:
      - PODMAN_MACHINE_CPUS
      - PODMAN_MACHINE_MEMORY
      - PODMAN_MACHINE_DISK_SIZE
      - PODMAN_MACHINE_ROOTFUL
      - PODMAN_MACHINE_AUTO_RESOURCE_UPDATE

options:
  PODMAN_PATH:
    description: Path to the podman binary. Falls back to podman on PATH.
    default: podman
  INACTIVITY_TIMEOUT:
    description: "Auto-stop container after inactivity period. Examples: 10m, 1h"
  PODMAN_MACHINE_AUTO_START:
    description: Automatically start the Podman machine if it is stopped.
    default: "true"
  PODMAN_MACHINE_AUTO_INIT:
    description: Automatically initialize a Podman machine if none exists.
    default: "false"
  PODMAN_MACHINE_NAME:
    description: Name of the Podman machine to use. Auto-detects if empty.
  PODMAN_MACHINE_START_TIMEOUT:
    description: Seconds to wait for the machine to become ready.
    default: "60"
  PODMAN_MACHINE_CPUS:
    description: CPUs to allocate to the machine (used on init only).
    default: "2"
  PODMAN_MACHINE_MEMORY:
    description: Memory in MB to allocate (used on init only).
    default: "4096"
  PODMAN_MACHINE_DISK_SIZE:
    description: Disk size in GB to allocate (used on init only).
    default: "100"
  PODMAN_MACHINE_ROOTFUL:
    description: Run machine in rootful mode.
    default: "false"
  PODMAN_MACHINE_AUTO_RESOURCE_UPDATE:
    description: Apply resource changes in-place via `podman machine set` without recreating the machine.
    default: "false"

agent:
  containerInactivityTimeout: ${INACTIVITY_TIMEOUT}
  local: true
  docker:
    path: ${PODMAN_PATH}
    install: false

exec:
  # DEV: hardcoded path — replace with binaries block before releasing (see Task 10)
  init: pwsh -NonInteractive -NoProfile -File "C:\Users\robejess\Developer\devpod-podman-powershell\scripts\init.ps1"
  command: '"${DEVPOD}" helper sh -c "${COMMAND}"'
```

- [ ] **Step 2: Register the provider with DevPod**

```powershell
devpod provider add C:\Users\robejess\Developer\devpod-podman-powershell
```

Expected: DevPod prints `Provider 'podman-windows' has been created`.

If the provider already exists from a previous add, delete it first:
```powershell
devpod provider delete podman-windows
devpod provider add C:\Users\robejess\Developer\devpod-podman-powershell
```

- [ ] **Step 3: Verify DevPod can see the provider options**

```powershell
devpod provider list
```

Expected: `podman-windows` appears in the list.

- [ ] **Step 4: Commit**

```bash
git add provider.yaml
git commit -m "feat: add provider.yaml (dev version)"
```

---

## Task 3: `init.ps1` — binary resolution and version

**Files:**
- Create: `scripts/init.ps1`

Build the script incrementally. This task creates the file with just Steps 1–2 of the init logic.

- [ ] **Step 1: Create `scripts/init.ps1`**

```powershell
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ── 1. Resolve podman binary ─────────────────────────────────────────────────
$podman = Get-Command $env:PODMAN_PATH -ErrorAction SilentlyContinue
if (-not $podman) {
    $podman = Get-Command podman -ErrorAction SilentlyContinue
}
if (-not $podman) {
    Write-Error ("Podman not found at '$env:PODMAN_PATH' and not on PATH. " +
                 "Install from https://github.com/containers/podman/releases " +
                 "or set PODMAN_PATH to the correct location.")
    exit 1
}
$podmanExe = $podman.Source

# ── 2. Print version ─────────────────────────────────────────────────────────
$versionOutput = & $podmanExe --version
Write-Host "Found $versionOutput"
```

- [ ] **Step 2: Test — podman on PATH (happy path)**

Run in PowerShell with the default env var:

```powershell
$env:PODMAN_PATH = 'podman'
pwsh -NonInteractive -NoProfile -File scripts\init.ps1
```

Expected output starts with `Found podman version X.Y.Z`.

- [ ] **Step 3: Test — bad path falls back to PATH**

```powershell
$env:PODMAN_PATH = 'C:\does\not\exist\podman.exe'
pwsh -NonInteractive -NoProfile -File scripts\init.ps1
```

Expected: script does NOT error on the bad path; it falls back to `podman` on PATH and prints version. (If podman is not on PATH at all you'll get the error message — that's also correct.)

- [ ] **Step 4: Test — nothing resolvable**

Temporarily rename/move podman to verify the error path. Or just run with a nonsense `PODMAN_PATH` in an environment where `podman` is not on PATH:

```powershell
$env:PODMAN_PATH = 'definitely-not-podman'
$env:PATH = ''  # nuke PATH so fallback also fails
pwsh -NonInteractive -NoProfile -File scripts\init.ps1
```

Expected: exits non-zero with error message mentioning the install URL.

Restore PATH after test.

- [ ] **Step 5: Commit**

```bash
git add scripts/init.ps1
git commit -m "feat: init.ps1 binary resolution and version print"
```

---

## Task 4: `init.ps1` — machine name resolution

**Files:**
- Modify: `scripts/init.ps1` (append after Step 2)

- [ ] **Step 1: Append machine name resolution to `scripts/init.ps1`**

Add after the `Write-Host "Found $versionOutput"` line:

```powershell
# ── 3. Resolve machine name ───────────────────────────────────────────────────
$machineName = $env:PODMAN_MACHINE_NAME

if (-not $machineName) {
    $listJson = & $podmanExe machine list --format json 2>&1
    if ($LASTEXITCODE -eq 0 -and $listJson) {
        $machines = $listJson | ConvertFrom-Json
        if ($machines -and $machines.Count -gt 0) {
            # Strip trailing '*' that Podman appends to the active machine name
            $machineName = ($machines[0].Name) -replace '\*$', ''
            Write-Host "Auto-detected machine: $machineName"
        }
    }
}
```

- [ ] **Step 2: Test — machine name from env var**

```powershell
$env:PODMAN_PATH = 'podman'
$env:PODMAN_MACHINE_NAME = 'my-test-machine'
pwsh -NonInteractive -NoProfile -File scripts\init.ps1
```

Expected: script reaches the machine name resolution step, uses `my-test-machine` without calling `podman machine list`. Script will then fail further down (that's fine — we haven't written those steps yet).

- [ ] **Step 3: Test — auto-detect from podman machine list**

```powershell
$env:PODMAN_PATH = 'podman'
Remove-Item Env:\PODMAN_MACHINE_NAME -ErrorAction SilentlyContinue
pwsh -NonInteractive -NoProfile -File scripts\init.ps1
```

Expected: prints `Auto-detected machine: <your machine name>` if a machine exists, or `$machineName` is empty if none. Script fails further down (expected).

- [ ] **Step 4: Commit**

```bash
git add scripts/init.ps1
git commit -m "feat: init.ps1 machine name resolution"
```

---

## Task 5: `init.ps1` — machine existence and auto-init

**Files:**
- Modify: `scripts/init.ps1` (append after Step 3)

- [ ] **Step 1: Append machine existence logic to `scripts/init.ps1`**

Add after the machine name resolution block:

```powershell
# ── 4. Machine existence ──────────────────────────────────────────────────────
if (-not $machineName) {
    if ($env:PODMAN_MACHINE_AUTO_INIT -eq 'true') {
        $machineName = 'devpod-machine'
        Write-Host "No Podman machine found. Creating '$machineName'..."

        $initArgs = @(
            'machine', 'init', $machineName,
            '--cpus',      $env:PODMAN_MACHINE_CPUS,
            '--memory',    $env:PODMAN_MACHINE_MEMORY,
            '--disk-size', $env:PODMAN_MACHINE_DISK_SIZE
        )
        if ($env:PODMAN_MACHINE_ROOTFUL -eq 'true') {
            $initArgs += '--rootful'
        }

        & $podmanExe @initArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to initialize Podman machine '$machineName'."
            exit 1
        }
        Write-Host "Machine '$machineName' created successfully."
    }
    else {
        Write-Error @"
No Podman machine found.

Manual fix:
  podman machine init
  podman machine start

Or enable auto-init:
  devpod provider set-options podman-windows PODMAN_MACHINE_AUTO_INIT=true
"@
        exit 1
    }
}
```

- [ ] **Step 2: Test — no machine, AUTO_INIT=false (default)**

Ensure you have no Podman machine (or rename your machine temporarily). Then:

```powershell
$env:PODMAN_PATH = 'podman'
Remove-Item Env:\PODMAN_MACHINE_NAME -ErrorAction SilentlyContinue
$env:PODMAN_MACHINE_AUTO_INIT = 'false'
$env:PODMAN_MACHINE_CPUS = '2'
$env:PODMAN_MACHINE_MEMORY = '4096'
$env:PODMAN_MACHINE_DISK_SIZE = '100'
$env:PODMAN_MACHINE_ROOTFUL = 'false'
pwsh -NonInteractive -NoProfile -File scripts\init.ps1
```

Expected: exits non-zero, prints the "No Podman machine found" error with manual fix instructions.

- [ ] **Step 3: Test — AUTO_INIT=true (skip if you already have a machine)**

Only run this if you want to create a fresh machine. **This will call `podman machine init` for real.**

```powershell
$env:PODMAN_MACHINE_AUTO_INIT = 'true'
$env:PODMAN_MACHINE_CPUS = '2'
$env:PODMAN_MACHINE_MEMORY = '4096'
$env:PODMAN_MACHINE_DISK_SIZE = '100'
$env:PODMAN_MACHINE_ROOTFUL = 'false'
pwsh -NonInteractive -NoProfile -File scripts\init.ps1
```

Expected: prints "Creating 'devpod-machine'..." and runs `podman machine init`. Script then fails further down (expected at this stage).

- [ ] **Step 4: Commit**

```bash
git add scripts/init.ps1
git commit -m "feat: init.ps1 machine existence check and auto-init"
```

---

## Task 6: `init.ps1` — machine state and auto-start

**Files:**
- Modify: `scripts/init.ps1` (append after Step 4)

- [ ] **Step 1: Append machine state and auto-start logic**

Add after the machine existence block. Note that `podman machine inspect` returns a JSON array; we take the first element.

```powershell
# ── 5. Machine state ──────────────────────────────────────────────────────────
$inspectJson = & $podmanExe machine inspect $machineName 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to inspect machine '$machineName': $inspectJson"
    exit 1
}
$inspect = ($inspectJson | ConvertFrom-Json)[0]
$state = $inspect.State
Write-Host "Machine '$machineName' state: $state"

if ($state -ne 'running') {
    if ($env:PODMAN_MACHINE_AUTO_START -eq 'true') {
        Write-Host "Starting machine '$machineName'..."
        & $podmanExe machine start $machineName
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to start machine '$machineName'."
            exit 1
        }

        $timeout = [int]$env:PODMAN_MACHINE_START_TIMEOUT
        $elapsed = 0
        Write-Host "Waiting for machine to be ready (timeout: ${timeout}s)..."
        while ($elapsed -lt $timeout) {
            $null = & $podmanExe ps 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Machine ready after ${elapsed}s."
                break
            }
            Start-Sleep -Seconds 2
            $elapsed += 2
        }
        if ($elapsed -ge $timeout) {
            Write-Error ("Machine start timed out after ${timeout}s. " +
                         "Increase timeout: devpod provider set-options podman-windows PODMAN_MACHINE_START_TIMEOUT=120")
            exit 1
        }
    }
    else {
        Write-Error @"
Machine '$machineName' is not running.

Manual fix:
  podman machine start $machineName

Or enable auto-start:
  devpod provider set-options podman-windows PODMAN_MACHINE_AUTO_START=true
"@
        exit 1
    }
}
else {
    Write-Host "Machine '$machineName' is already running."
    # Resource mismatch check goes here in Task 7
}
```

- [ ] **Step 2: Test — machine stopped, AUTO_START=false**

Stop your machine first: `podman machine stop`

```powershell
$env:PODMAN_PATH = 'podman'
Remove-Item Env:\PODMAN_MACHINE_NAME -ErrorAction SilentlyContinue
$env:PODMAN_MACHINE_AUTO_INIT = 'false'
$env:PODMAN_MACHINE_AUTO_START = 'false'
$env:PODMAN_MACHINE_START_TIMEOUT = '60'
pwsh -NonInteractive -NoProfile -File scripts\init.ps1
```

Expected: prints state `stopped`, then errors with the manual start instructions.

- [ ] **Step 3: Test — machine stopped, AUTO_START=true**

```powershell
$env:PODMAN_MACHINE_AUTO_START = 'true'
pwsh -NonInteractive -NoProfile -File scripts\init.ps1
```

Expected: prints "Starting machine...", waits for readiness, then prints "Machine ready after Xs." Script continues (may fail at end — that's fine, connectivity check not written yet).

- [ ] **Step 4: Test — machine already running**

With machine running:

```powershell
$env:PODMAN_MACHINE_AUTO_START = 'true'
pwsh -NonInteractive -NoProfile -File scripts\init.ps1
```

Expected: prints `state: running` and `Machine '...' is already running.` Script continues.

- [ ] **Step 5: Commit**

```bash
git add scripts/init.ps1
git commit -m "feat: init.ps1 machine state check and auto-start"
```

---

## Task 7: `init.ps1` — resource mismatch detection and warning

**Files:**
- Modify: `scripts/init.ps1` (fill in the `else` branch for "already running")

`podman machine inspect` returns `Resources.CPUs` (int), `Resources.Memory` (int, MB), `Resources.DiskSize` (int, GB), and `Rootful` (bool) at the top level. Verify these field names on your system with `podman machine inspect | ConvertFrom-Json | Select-Object -ExpandProperty Resources` before running.

- [ ] **Step 1: Replace the `# Resource mismatch check goes here` comment with the warning logic**

Inside the `else { Write-Host "Machine '...' is already running." }` block, add:

```powershell
    # ── 6a. Resource mismatch — detect and warn ───────────────────────────────
    $currentCpus    = $inspect.Resources.CPUs
    $currentMemoryMb = $inspect.Resources.Memory
    $currentDiskGb  = $inspect.Resources.DiskSize
    $currentRootful = [bool]$inspect.Rootful

    $desiredCpus    = [int]$env:PODMAN_MACHINE_CPUS
    $desiredMemoryMb = [int]$env:PODMAN_MACHINE_MEMORY
    $desiredDiskGb  = [int]$env:PODMAN_MACHINE_DISK_SIZE
    $desiredRootful = ($env:PODMAN_MACHINE_ROOTFUL -eq 'true')

    $mismatches = @()
    if ($currentCpus     -ne $desiredCpus)     { $mismatches += "  CPUs:    current=$currentCpus  desired=$desiredCpus" }
    if ($currentMemoryMb -ne $desiredMemoryMb)  { $mismatches += "  Memory:  current=${currentMemoryMb}MB  desired=${desiredMemoryMb}MB" }
    if ($currentDiskGb   -ne $desiredDiskGb)    { $mismatches += "  Disk:    current=${currentDiskGb}GB  desired=${desiredDiskGb}GB" }
    if ($currentRootful  -ne $desiredRootful)   { $mismatches += "  Rootful: current=$currentRootful  desired=$desiredRootful" }

    if ($mismatches.Count -gt 0) {
        if ($env:PODMAN_MACHINE_AUTO_RESOURCE_UPDATE -eq 'true') {
            # Auto-update handled in Task 8 — placeholder to keep structure
        }
        else {
            Write-Warning "Resource configuration mismatch detected for '$machineName':"
            $mismatches | ForEach-Object { Write-Warning $_ }
            Write-Warning ""
            Write-Warning ("To apply in-place: " +
                           "devpod provider set-options podman-windows PODMAN_MACHINE_AUTO_RESOURCE_UPDATE=true")
            Write-Warning "Continuing with existing configuration..."
        }
    }
```

- [ ] **Step 2: Test — running machine, mismatched CPU count**

With machine running and default CPUs=2:

```powershell
$env:PODMAN_MACHINE_CPUS = '999'   # deliberately wrong
$env:PODMAN_MACHINE_MEMORY = '4096'
$env:PODMAN_MACHINE_DISK_SIZE = '100'
$env:PODMAN_MACHINE_ROOTFUL = 'false'
$env:PODMAN_MACHINE_AUTO_RESOURCE_UPDATE = 'false'
pwsh -NonInteractive -NoProfile -File scripts\init.ps1
```

Expected: prints the mismatch warning for CPUs, then continues (script ends — connectivity check not written yet).

- [ ] **Step 3: Test — running machine, no mismatch**

```powershell
# Set env vars to match your actual machine config
$env:PODMAN_MACHINE_CPUS = '2'
$env:PODMAN_MACHINE_MEMORY = '4096'
$env:PODMAN_MACHINE_DISK_SIZE = '100'
$env:PODMAN_MACHINE_ROOTFUL = 'false'
$env:PODMAN_MACHINE_AUTO_RESOURCE_UPDATE = 'false'
pwsh -NonInteractive -NoProfile -File scripts\init.ps1
```

Expected: no warning printed; script continues.

- [ ] **Step 4: Commit**

```bash
git add scripts/init.ps1
git commit -m "feat: init.ps1 resource mismatch detection and warning"
```

---

## Task 8: `init.ps1` — resource auto-update

**Files:**
- Modify: `scripts/init.ps1` (fill in the `AUTO_RESOURCE_UPDATE=true` branch)

- [ ] **Step 1: Replace the `# Auto-update handled in Task 8` placeholder with real logic**

Replace the placeholder comment inside `if ($env:PODMAN_MACHINE_AUTO_RESOURCE_UPDATE -eq 'true')` with:

```powershell
            # Reject disk shrink — Podman does not support it
            $diskMismatch = ($currentDiskGb -ne $desiredDiskGb)
            $diskShrink   = ($desiredDiskGb -lt $currentDiskGb)
            if ($diskShrink) {
                Write-Warning ("Cannot decrease disk from ${currentDiskGb}GB to ${desiredDiskGb}GB. " +
                               "Podman does not support disk shrink. Skipping disk update.")
                $diskMismatch = $false
            }

            Write-Host "Stopping '$machineName' to apply resource changes..."
            & $podmanExe machine stop $machineName
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to stop machine '$machineName'."
                exit 1
            }

            if ($currentCpus -ne $desiredCpus) {
                Write-Host "  Setting CPUs to $desiredCpus..."
                & $podmanExe machine set $machineName --cpus $desiredCpus
            }
            if ($currentMemoryMb -ne $desiredMemoryMb) {
                Write-Host "  Setting memory to ${desiredMemoryMb}MB..."
                & $podmanExe machine set $machineName --memory $desiredMemoryMb
            }
            if ($diskMismatch) {
                Write-Host "  Setting disk to ${desiredDiskGb}GB..."
                & $podmanExe machine set $machineName --disk-size $desiredDiskGb
            }
            if ($currentRootful -ne $desiredRootful) {
                Write-Host "  Setting rootful to $desiredRootful..."
                if ($desiredRootful) {
                    & $podmanExe machine set $machineName --rootful
                } else {
                    & $podmanExe machine set $machineName --rootful=false
                }
            }

            Write-Host "Restarting '$machineName'..."
            & $podmanExe machine start $machineName
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Failed to restart machine after resource update."
                exit 1
            }

            $timeout = [int]$env:PODMAN_MACHINE_START_TIMEOUT
            $elapsed = 0
            while ($elapsed -lt $timeout) {
                $null = & $podmanExe ps 2>&1
                if ($LASTEXITCODE -eq 0) { Write-Host "Machine ready after ${elapsed}s."; break }
                Start-Sleep -Seconds 2; $elapsed += 2
            }
            if ($elapsed -ge $timeout) {
                Write-Error "Machine start timed out after ${timeout}s after resource update."
                exit 1
            }
            Write-Host "Resource update complete."
```

- [ ] **Step 2: Test — AUTO_RESOURCE_UPDATE=true, disk shrink rejected**

```powershell
$env:PODMAN_MACHINE_CPUS = '2'
$env:PODMAN_MACHINE_MEMORY = '4096'
$env:PODMAN_MACHINE_DISK_SIZE = '1'   # smaller than current — should be rejected
$env:PODMAN_MACHINE_ROOTFUL = 'false'
$env:PODMAN_MACHINE_AUTO_RESOURCE_UPDATE = 'true'
$env:PODMAN_MACHINE_START_TIMEOUT = '60'
pwsh -NonInteractive -NoProfile -File scripts\init.ps1
```

Expected: warning about disk shrink not supported, skips disk update, continues with other updates (if any), restarts machine.

- [ ] **Step 3: Test — AUTO_RESOURCE_UPDATE=true, legitimate CPU change**

Set `PODMAN_MACHINE_CPUS` to a value different from your current machine's CPU count. The script will stop and restart the machine. **Only run if you're comfortable with the machine briefly stopping.**

```powershell
# Check current CPU count first:
podman machine inspect | ConvertFrom-Json | ForEach-Object { $_.Resources.CPUs }

# Set to a different value, e.g., if current is 2:
$env:PODMAN_MACHINE_CPUS = '4'
$env:PODMAN_MACHINE_AUTO_RESOURCE_UPDATE = 'true'
$env:PODMAN_MACHINE_START_TIMEOUT = '120'
pwsh -NonInteractive -NoProfile -File scripts\init.ps1
```

Expected: stops machine, sets CPUs, restarts, polls until ready, prints "Resource update complete."

Restore the original CPU count after testing.

- [ ] **Step 4: Commit**

```bash
git add scripts/init.ps1
git commit -m "feat: init.ps1 resource auto-update"
```

---

## Task 9: `init.ps1` — connectivity check and full integration

**Files:**
- Modify: `scripts/init.ps1` (append after the outer if/else block)

- [ ] **Step 1: Append the connectivity check at the end of `scripts/init.ps1`**

After the closing `}` of the `if ($state -ne 'running') { ... } else { ... }` block:

```powershell
# ── 7. Connectivity check ─────────────────────────────────────────────────────
Write-Host "Testing Podman connectivity..."
$null = & $podmanExe ps 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error ("Podman is not reachable. " +
                 "Check machine status with: podman machine list")
    exit 1
}

Write-Host "Podman provider initialized successfully."
```

- [ ] **Step 2: Run the full script with your real machine**

Set all env vars to their defaults and run the complete script:

```powershell
$env:PODMAN_PATH                   = 'podman'
$env:PODMAN_MACHINE_AUTO_START     = 'true'
$env:PODMAN_MACHINE_AUTO_INIT      = 'false'
$env:PODMAN_MACHINE_START_TIMEOUT  = '60'
$env:PODMAN_MACHINE_CPUS           = '2'
$env:PODMAN_MACHINE_MEMORY         = '4096'
$env:PODMAN_MACHINE_DISK_SIZE      = '100'
$env:PODMAN_MACHINE_ROOTFUL        = 'false'
$env:PODMAN_MACHINE_AUTO_RESOURCE_UPDATE = 'false'
Remove-Item Env:\PODMAN_MACHINE_NAME -ErrorAction SilentlyContinue

pwsh -NonInteractive -NoProfile -File scripts\init.ps1
```

Expected final line: `Podman provider initialized successfully.`

- [ ] **Step 3: Full DevPod integration test**

Run a real DevPod workspace using the provider:

```powershell
devpod up https://github.com/microsoft/vscode-remote-try-python --provider podman-windows --ide none
```

Expected: DevPod initialises the provider (runs init.ps1), pulls the container, and reports the workspace is up.

Check the workspace is running:
```powershell
devpod list
```

Clean up:
```powershell
devpod delete <workspace-name>
```

- [ ] **Step 4: Run the full testing checklist from the spec**

Work through each scenario manually:

```
[ ] No machine, AUTO_INIT=false → clear error message
[ ] No machine, AUTO_INIT=true  → machine created and started
[ ] Machine stopped, AUTO_START=true → machine started
[ ] Machine running, mismatch, AUTO_RESOURCE_UPDATE=false → warning, continues
[ ] Machine running, mismatch, AUTO_RESOURCE_UPDATE=true  → updated in-place
[ ] Disk shrink → rejected with clear error
[ ] devpod up end-to-end → workspace comes up
```

- [ ] **Step 5: Commit**

```bash
git add scripts/init.ps1
git commit -m "feat: init.ps1 connectivity check — init script complete"
```

---

## Task 10: Release workflow and production `provider.yaml`

**Files:**
- Create: `.github/workflows/release.yml`
- Modify: `provider.yaml` (swap dev exec for binaries block)

This task wires up GitHub releases so others can install the provider with a URL.

- [ ] **Step 1: Create `.github/workflows/release.yml`**

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4

      - name: Compute checksum
        id: checksum
        run: |
          SHA=$(sha256sum scripts/init.ps1 | awk '{print $1}')
          echo "sha256=$SHA" >> $GITHUB_OUTPUT
          echo "Checksum: $SHA"

      - name: Create GitHub Release and upload init.ps1
        uses: softprops/action-gh-release@v2
        with:
          files: scripts/init.ps1
          body: |
            ## Install

            ```
            devpod provider add https://github.com/${{ github.repository }}/releases/download/${{ github.ref_name }}/provider.yaml
            ```

            **init.ps1 SHA256:** `${{ steps.checksum.outputs.sha256 }}`

      - name: Upload provider.yaml to release
        uses: softprops/action-gh-release@v2
        with:
          files: provider.yaml
```

- [ ] **Step 2: Update `provider.yaml` — swap dev exec for binaries**

Replace the `exec` and add `binaries` in `provider.yaml`. Update `version` and the release URL to match your tag (e.g. `v0.1.0`):

```yaml
version: v0.1.0

binaries:
  INIT_SCRIPT:
    - os: windows
      arch: amd64
      path: https://github.com/robejess/devpod-podman-powershell/releases/download/v0.1.0/init.ps1
      checksum: ""  # paste SHA256 from release workflow output after first release

exec:
  init: pwsh -NonInteractive -NoProfile -File "${INIT_SCRIPT}"
  command: '"${DEVPOD}" helper sh -c "${COMMAND}"'
```

Remove the dev `exec.init` line (the hardcoded local path). The `binaries` section replaces it.

- [ ] **Step 3: Re-register the provider with DevPod to pick up changes**

```powershell
devpod provider delete podman-windows
devpod provider add C:\Users\robejess\Developer\devpod-podman-powershell
```

- [ ] **Step 4: Commit and tag**

```bash
git add .github/ provider.yaml
git commit -m "feat: release workflow and production provider.yaml"
git tag v0.1.0
git push origin main --tags
```

- [ ] **Step 5: After the release workflow runs, paste the checksum**

The workflow prints the SHA256 in the "Compute checksum" step. Once the workflow completes:

1. Copy the SHA256 from the Actions log
2. Paste it into `provider.yaml` under `checksum:`
3. Commit: `git commit -am "chore: add release checksum for v0.1.0"`
4. Push (no new tag needed — this is a metadata fix)

- [ ] **Step 6: Verify remote install**

```powershell
devpod provider delete podman-windows
devpod provider add https://github.com/robejess/devpod-podman-powershell/releases/download/v0.1.0/provider.yaml
devpod provider list
```

Expected: `podman-windows` appears in the list, installed from the remote URL.
