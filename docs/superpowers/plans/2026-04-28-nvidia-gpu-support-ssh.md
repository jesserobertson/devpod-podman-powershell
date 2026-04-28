# NVIDIA GPU Support — SSH Post-Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the non-functional cloud-init approach with an idempotent SSH post-setup step that installs the NVIDIA Container Toolkit and generates CDI specs after the machine is confirmed running.

**Architecture:** After the machine reaches running state in `init.ps1`, a new step SSHs in via `podman machine ssh` to check for `/etc/cdi/nvidia.yaml` and install the toolkit if missing. The check is fast (~1s) so it runs on every `devpod up` call without meaningful overhead.

**Tech Stack:** PowerShell 7 (pwsh), Pester 5 (tests), `podman machine ssh`

---

## File Map

| File | Change |
|---|---|
| `provider.yaml` | Update `PODMAN_MACHINE_NVIDIA_GPU` description |
| `scripts/init.ps1` | Remove cloud-init block; add SSH CDI setup step after machine is running |
| `tests/mocks/podman-running.ps1` | Add `machine ssh` handler returning `exists` |
| `tests/mocks/podman-running-no-cdi.ps1` | New mock: running machine, SSH returns `missing` |
| `tests/mocks/podman-no-machine-gpu.ps1` | Delete (no longer needed) |
| `tests/init.Tests.ps1` | Replace cloud-init GPU contexts with SSH CDI contexts |
| `README.md` | Update GPU section: works on existing machines, no recreation required |

---

### Task 1: Update `provider.yaml` description and remove cloud-init from `init.ps1`

**Files:**
- Modify: `provider.yaml`
- Modify: `scripts/init.ps1`

- [ ] **Step 1: Update description in `provider.yaml`**

Find the `PODMAN_MACHINE_NVIDIA_GPU` option and replace its description:

```yaml
  PODMAN_MACHINE_NVIDIA_GPU:
    description: >
      After the machine starts, install the NVIDIA Container Toolkit via SSH
      and generate CDI specs if not already present. Enables --gpus all in
      devcontainers. Works on both new and existing machines.
    default: "false"
```

- [ ] **Step 2: Remove cloud-init block from `init.ps1`**

In `scripts/init.ps1`, inside the `if ($env:PODMAN_MACHINE_AUTO_INIT -eq 'true')` block, remove everything related to `$userDataFile`:

- The `$userDataFile = $null` line
- The `if ($env:PODMAN_MACHINE_NVIDIA_GPU -eq 'true') { ... }` block that writes the YAML
- The `Remove-Item $userDataFile` cleanup line
- Change `$podmanInitExit` back to using `$LASTEXITCODE` directly (or keep the variable — either is fine)

Also remove the section `# ── 3a. GPU option — warn if machine already exists` block entirely.

The machine init block should return to a clean state:

```powershell
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
```

- [ ] **Step 3: Run tests — confirm existing tests still pass**

```powershell
Invoke-Pester -Path tests\init.Tests.ps1 -Output Detailed
```

Expected: the 9 original non-GPU tests pass. The 3 GPU tests will now fail (we'll fix them in Task 2). That's fine — confirm only the original 9 pass cleanly.

- [ ] **Step 4: Commit**

```bash
git add provider.yaml scripts/init.ps1
git commit -m "refactor: remove cloud-init GPU approach (--user-data not supported on WSL2)"
```

---

### Task 2: Replace GPU tests with SSH CDI tests

**Files:**
- Modify: `tests/mocks/podman-running.ps1`
- Create: `tests/mocks/podman-running-no-cdi.ps1`
- Delete: `tests/mocks/podman-no-machine-gpu.ps1`
- Modify: `tests/init.Tests.ps1`

- [ ] **Step 1: Add `machine ssh` handler to `podman-running.ps1`**

Open `tests/mocks/podman-running.ps1`. In the `'machine'` switch block, add a `'ssh'` case that returns `exists` (CDI specs present):

```powershell
            'ssh'   {
                # Return CDI-present status for the idempotency check
                Write-Output 'exists'; exit 0
            }
```

The full machine switch block should look like:

```powershell
    'machine' {
        switch ($args[1]) {
            'list' {
                Write-Output '[{"Name":"test-machine","Running":true}]'
                exit 0
            }
            'inspect' {
                Write-Output '[{"Name":"test-machine","State":"running","Resources":{"CPUs":2,"Memory":4096,"DiskSize":100},"Rootful":false}]'
                exit 0
            }
            'start' { exit 0 }
            'stop'  { exit 0 }
            'set'   { exit 0 }
            'ssh'   { Write-Output 'exists'; exit 0 }
        }
    }
```

- [ ] **Step 2: Create `tests/mocks/podman-running-no-cdi.ps1`**

Copy of `podman-running.ps1` but `machine ssh` returns `missing`:

```powershell
# Mock podman: one machine named 'test-machine', running, CDI specs absent
param()

switch ($args[0]) {
    '--version' { Write-Output 'podman version 5.0.0'; exit 0 }
    'machine' {
        switch ($args[1]) {
            'list' {
                Write-Output '[{"Name":"test-machine","Running":true}]'
                exit 0
            }
            'inspect' {
                Write-Output '[{"Name":"test-machine","State":"running","Resources":{"CPUs":2,"Memory":4096,"DiskSize":100},"Rootful":false}]'
                exit 0
            }
            'start' { exit 0 }
            'stop'  { exit 0 }
            'set'   { exit 0 }
            'ssh'   { Write-Output 'missing'; exit 0 }
        }
    }
    'ps' { exit 0 }
    default { exit 1 }
}
```

- [ ] **Step 3: Delete `tests/mocks/podman-no-machine-gpu.ps1`**

```bash
git rm tests/mocks/podman-no-machine-gpu.ps1
```

- [ ] **Step 4: Replace GPU test contexts in `tests/init.Tests.ps1`**

Remove the two existing GPU `Context` blocks:
- `Context 'no machine, AUTO_INIT=true, NVIDIA_GPU=true'`
- `Context 'existing machine, NVIDIA_GPU=true'`

Replace them with:

```powershell
    Context 'running machine, NVIDIA_GPU=true, CDI missing' {
        It 'runs SSH setup and exits 0' {
            $result = Invoke-Init @{
                PODMAN_PATH               = (Join-Path $script:MocksDir 'podman-running-no-cdi.ps1')
                PODMAN_MACHINE_NVIDIA_GPU = 'true'
            }
            $result.ExitCode | Should -Be 0
            $result.Text     | Should -Match 'Installing NVIDIA Container Toolkit'
            $result.Output   | Should -Contain 'Podman provider initialized successfully.'
        }
    }

    Context 'running machine, NVIDIA_GPU=true, CDI present' {
        It 'skips SSH setup and exits 0' {
            $result = Invoke-Init @{
                PODMAN_PATH               = (Join-Path $script:MocksDir 'podman-running.ps1')
                PODMAN_MACHINE_NVIDIA_GPU = 'true'
            }
            $result.ExitCode | Should -Be 0
            $result.Text     | Should -Match 'already present'
            $result.Output   | Should -Contain 'Podman provider initialized successfully.'
        }
    }
```

- [ ] **Step 5: Run tests — verify new GPU tests fail, original 9 still pass**

```powershell
Invoke-Pester -Path tests\init.Tests.ps1 -Output Detailed
```

Expected: 9 original tests pass, 2 new GPU tests fail.

- [ ] **Step 6: Commit**

```bash
git add tests/mocks/podman-running.ps1 tests/mocks/podman-running-no-cdi.ps1 tests/init.Tests.ps1
git commit -m "test: replace cloud-init GPU tests with SSH CDI setup tests"
```

---

### Task 3: Implement SSH CDI setup in `scripts/init.ps1`

**Files:**
- Modify: `scripts/init.ps1`

- [ ] **Step 1: Add SSH CDI setup step**

Read the current `scripts/init.ps1`. After the readiness loop in step 5 (the `while ($elapsed -lt $timeout)` block that ends with `Write-Host "Machine ready after ${elapsed}s."`), insert a new section before step 7 (connectivity check):

```powershell
# ── 6b. NVIDIA GPU setup ──────────────────────────────────────────────────────
if ($env:PODMAN_MACHINE_NVIDIA_GPU -eq 'true') {
    Write-Host "Checking NVIDIA CDI specs on '$machineName'..."
    $cdiStatus = & $podmanExe machine ssh $machineName `
        "test -f /etc/cdi/nvidia.yaml && echo exists || echo missing" 2>&1
    if ($cdiStatus -notmatch 'exists') {
        Write-Host "CDI specs not found. Installing NVIDIA Container Toolkit (this may take a few minutes)..."
        & $podmanExe machine ssh $machineName "sudo curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo -o /etc/yum.repos.d/nvidia-container-toolkit.repo && sudo dnf install -y nvidia-container-toolkit && sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
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

Note: this block must appear in the `if ($state -ne 'running')` / `else` flow such that it runs in BOTH branches (new machine that was just started, AND already-running machine). The safest place is immediately before `# ── 7. Connectivity check`.

- [ ] **Step 2: Run tests — verify all 11 pass**

```powershell
Invoke-Pester -Path tests\init.Tests.ps1 -Output Detailed
```

Expected: all 11 tests pass (9 original + 2 new GPU tests).

- [ ] **Step 3: Commit**

```bash
git add scripts/init.ps1
git commit -m "feat: replace cloud-init with SSH post-setup for NVIDIA CDI specs"
```

---

### Task 4: Update `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the GPU support section**

Replace the existing `## GPU support` section with:

```markdown
## GPU support

To enable NVIDIA GPU passthrough in devcontainers, set `PODMAN_MACHINE_NVIDIA_GPU=true`.
On each `devpod up`, the provider SSHs into the machine and installs the
[NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/)
if not already present, then generates CDI specs. The check is fast (~1 second) when the
toolkit is already installed.

Works on both new and existing machines — no recreation required.

```powershell
devpod provider set-options podman-windows -o PODMAN_MACHINE_NVIDIA_GPU=true
devpod up .
```

**Verify GPU access:**

```powershell
podman run --rm --device nvidia.com/gpu=all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi
```

In `devcontainer.json`, use standard `runArgs`:

```json
"runArgs": ["--gpus", "all"]
```
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update GPU support section — SSH post-setup, works on existing machines"
```
