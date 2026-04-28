# NVIDIA GPU Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `PODMAN_MACHINE_NVIDIA_GPU` option to the `podman-windows` provider that passes a cloud-init user-data file to `podman machine init`, installing the NVIDIA Container Toolkit and generating CDI specs so `--gpus all` works in devcontainers.

**Architecture:** One new provider option triggers cloud-init injection at machine-creation time in `init.ps1`. The cloud-init YAML is written as a PowerShell here-string to a temp file, passed via `--user-data`, then deleted. A warning fires if the option is set but a machine already exists. WSL2 filesystem persistence means CDI specs survive machine restarts without any recurring setup.

**Tech Stack:** PowerShell 7 (pwsh), Pester 5 (tests), YAML (cloud-init), `podman machine init --user-data`

---

## File Map

| File | Change |
|---|---|
| `provider.yaml` | Add `PODMAN_MACHINE_NVIDIA_GPU` option to "Machine Management" group |
| `scripts/init.ps1` | Write cloud-init temp file + `--user-data` arg when GPU=true on init; warn when machine exists |
| `tests/mocks/podman-no-machine-gpu.ps1` | New mock that echoes `machine init` args so tests can assert `--user-data` was passed |
| `tests/init.Tests.ps1` | Add `PODMAN_MACHINE_NVIDIA_GPU` to `Invoke-Init` defaults; add two new GPU test contexts |
| `README.md` | Add "GPU support" section |

---

### Task 1: Add `PODMAN_MACHINE_NVIDIA_GPU` to `provider.yaml`

**Files:**
- Modify: `provider.yaml`

- [ ] **Step 1: Add the option**

In `provider.yaml`, add `PODMAN_MACHINE_NVIDIA_GPU` to the `optionGroups[Machine Management].options` list and add its definition to `options:`. Final relevant sections:

```yaml
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
      - PODMAN_MACHINE_NVIDIA_GPU
  - name: "Machine Resources"
    options:
      - PODMAN_MACHINE_CPUS
      - PODMAN_MACHINE_MEMORY
      - PODMAN_MACHINE_DISK_SIZE
      - PODMAN_MACHINE_ROOTFUL
      - PODMAN_MACHINE_AUTO_RESOURCE_UPDATE
```

And in the `options:` block, after `PODMAN_MACHINE_START_TIMEOUT`:

```yaml
  PODMAN_MACHINE_NVIDIA_GPU:
    description: >
      Pass a cloud-init user-data file to the machine on init that installs
      the NVIDIA Container Toolkit and generates CDI specs. Requires
      PODMAN_MACHINE_AUTO_INIT=true. Has no effect on already-existing machines.
    default: "false"
```

- [ ] **Step 2: Verify the YAML is valid**

```bash
cd C:\Users\robejess\Developer\devpod-podman-powershell
pwsh -Command "Import-Module powershell-yaml -ErrorAction SilentlyContinue; Get-Content provider.yaml | Out-Null; Write-Host 'OK'"
```

(If `powershell-yaml` isn't installed, just eyeball the indentation — YAML parse errors show up at provider install time.)

- [ ] **Step 3: Commit**

```bash
git add provider.yaml
git commit -m "feat: add PODMAN_MACHINE_NVIDIA_GPU option to provider.yaml"
```

---

### Task 2: Write GPU mock and failing Pester tests

**Files:**
- Create: `tests/mocks/podman-no-machine-gpu.ps1`
- Modify: `tests/init.Tests.ps1`

- [ ] **Step 1: Create the GPU mock**

Create `tests/mocks/podman-no-machine-gpu.ps1`. This is identical to `podman-no-machine.ps1` except `machine init` echoes all received arguments so tests can assert `--user-data` was passed:

```powershell
# Mock podman: no machines exist, echoes machine init args for GPU testing
param()

switch ($args[0]) {
    '--version' { Write-Output 'podman version 5.0.0'; exit 0 }
    'machine' {
        switch ($args[1]) {
            'list'    { Write-Output '[]'; exit 0 }
            'init'    { Write-Output "Machine init: $($args -join ' ')"; exit 0 }
            'start'   { exit 0 }
            'inspect' {
                Write-Output '[{"Name":"devpod-machine","State":"stopped","Resources":{"CPUs":2,"Memory":4096,"DiskSize":100},"Rootful":false}]'
                exit 0
            }
        }
    }
    'ps' { exit 0 }
    default { exit 1 }
}
```

- [ ] **Step 2: Add `PODMAN_MACHINE_NVIDIA_GPU` to `Invoke-Init` defaults**

In `tests/init.Tests.ps1`, find the `$defaults` hashtable inside `Invoke-Init` and add the new key so existing tests always run with GPU disabled:

```powershell
    $defaults = @{
        PODMAN_PATH                         = ''
        PODMAN_MACHINE_AUTO_START           = 'true'
        PODMAN_MACHINE_AUTO_INIT            = 'false'
        PODMAN_MACHINE_NAME                 = ''
        PODMAN_MACHINE_START_TIMEOUT        = '10'
        PODMAN_MACHINE_CPUS                 = '2'
        PODMAN_MACHINE_MEMORY               = '4096'
        PODMAN_MACHINE_DISK_SIZE            = '100'
        PODMAN_MACHINE_ROOTFUL              = 'false'
        PODMAN_MACHINE_AUTO_RESOURCE_UPDATE = 'false'
        PODMAN_MACHINE_NVIDIA_GPU           = 'false'
    }
```

- [ ] **Step 3: Add failing GPU test contexts**

Append these two `Context` blocks inside the `Describe 'init.ps1'` block in `tests/init.Tests.ps1`:

```powershell
    Context 'no machine, AUTO_INIT=true, NVIDIA_GPU=true' {
        BeforeAll {
            $script:TempUserData = Join-Path $env:TEMP 'podman-nvidia-userdata.yaml'
            if (Test-Path $script:TempUserData) { Remove-Item $script:TempUserData -Force }
        }

        It 'exits 0 and passes --user-data to machine init' {
            $result = Invoke-Init @{
                PODMAN_PATH               = (Join-Path $script:MocksDir 'podman-no-machine-gpu.ps1')
                PODMAN_MACHINE_AUTO_INIT  = 'true'
                PODMAN_MACHINE_AUTO_START = 'true'
                PODMAN_MACHINE_NVIDIA_GPU = 'true'
            }
            $result.ExitCode | Should -Be 0
            $result.Text     | Should -Match '--user-data'
        }

        It 'cleans up the temp user-data file after init' {
            $result = Invoke-Init @{
                PODMAN_PATH               = (Join-Path $script:MocksDir 'podman-no-machine-gpu.ps1')
                PODMAN_MACHINE_AUTO_INIT  = 'true'
                PODMAN_MACHINE_AUTO_START = 'true'
                PODMAN_MACHINE_NVIDIA_GPU = 'true'
            }
            $result.ExitCode      | Should -Be 0
            Test-Path $script:TempUserData | Should -Be $false
        }
    }

    Context 'existing machine, NVIDIA_GPU=true' {
        It 'warns that GPU option has no effect and exits 0' {
            $result = Invoke-Init @{
                PODMAN_PATH               = (Join-Path $script:MocksDir 'podman-running.ps1')
                PODMAN_MACHINE_NVIDIA_GPU = 'true'
            }
            $result.ExitCode | Should -Be 0
            $result.Text     | Should -Match 'no effect'
            $result.Output   | Should -Contain 'Podman provider initialized successfully.'
        }
    }
```

- [ ] **Step 4: Run tests — verify they fail**

```powershell
cd C:\Users\robejess\Developer\devpod-podman-powershell
pwsh -Command "Invoke-Pester -Path tests\init.Tests.ps1 -Output Detailed"
```

Expected: the three existing passing contexts still pass; the two new GPU contexts fail (the GPU logic doesn't exist yet).

- [ ] **Step 5: Commit**

```bash
git add tests/mocks/podman-no-machine-gpu.ps1 tests/init.Tests.ps1
git commit -m "test: add GPU mock and failing Pester tests for NVIDIA_GPU option"
```

---

### Task 3: Implement GPU logic in `scripts/init.ps1`

**Files:**
- Modify: `scripts/init.ps1`

- [ ] **Step 1: Add warning for existing machines**

After step 3 (machine name resolution, ending at `Write-Host "Auto-detected machine: $machineName"`) and before step 4 (`# ── 4. Machine existence`), insert:

```powershell
# ── 3a. GPU option — warn if machine already exists ───────────────────────
if ($machineName -and $env:PODMAN_MACHINE_NVIDIA_GPU -eq 'true') {
    Write-Warning ("PODMAN_MACHINE_NVIDIA_GPU=true has no effect on existing machine '$machineName'. " +
                   "To enable GPU support, recreate the machine: " +
                   "podman machine rm $machineName && devpod up . with PODMAN_MACHINE_AUTO_INIT=true")
}
```

- [ ] **Step 2: Inject cloud-init user-data on machine init**

Inside the `if ($env:PODMAN_MACHINE_AUTO_INIT -eq 'true')` block in step 4, replace the existing init block:

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

        $userDataFile = $null
        if ($env:PODMAN_MACHINE_NVIDIA_GPU -eq 'true') {
            $userDataFile = Join-Path $env:TEMP 'podman-nvidia-userdata.yaml'
            @'
#cloud-config
runcmd:
  - curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo -o /etc/yum.repos.d/nvidia-container-toolkit.repo
  - dnf install -y nvidia-container-toolkit
  - nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
'@ | Set-Content -Path $userDataFile -Encoding utf8
            $initArgs += '--user-data', $userDataFile
            Write-Host "GPU support enabled: NVIDIA Container Toolkit will be installed via cloud-init."
        }

        & $podmanExe @initArgs
        if ($null -ne $userDataFile) { Remove-Item $userDataFile -Force -ErrorAction SilentlyContinue }
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to initialize Podman machine '$machineName'."
            exit 1
        }
        Write-Host "Machine '$machineName' created successfully."
```

- [ ] **Step 3: Run tests — verify they pass**

```powershell
cd C:\Users\robejess\Developer\devpod-podman-powershell
pwsh -Command "Invoke-Pester -Path tests\init.Tests.ps1 -Output Detailed"
```

Expected: all contexts pass, including the two new GPU contexts.

- [ ] **Step 4: Commit**

```bash
git add scripts/init.ps1
git commit -m "feat: inject NVIDIA cloud-init user-data on machine init when PODMAN_MACHINE_NVIDIA_GPU=true"
```

---

### Task 4: Update `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add GPU support section**

Insert a new `## GPU support` section after the `## Options` table and before `## How it works`:

```markdown
## GPU support

To enable NVIDIA GPU passthrough in devcontainers, set `PODMAN_MACHINE_NVIDIA_GPU=true` before
the machine is created. On init, the machine receives a cloud-init user-data file that installs
the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/)
and generates CDI specs, making `nvidia.com/gpu=all` resolvable inside containers.

**New machine:**

```powershell
devpod provider set-options podman-windows `
  PODMAN_MACHINE_AUTO_INIT=true `
  PODMAN_MACHINE_NVIDIA_GPU=true

devpod up .
```

**Existing machine** (recreate required — cloud-init only runs on first boot):

```powershell
podman machine rm devpod-machine     # or your machine name
devpod provider set-options podman-windows `
  PODMAN_MACHINE_AUTO_INIT=true `
  PODMAN_MACHINE_NVIDIA_GPU=true
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
git commit -m "docs: add GPU support section to README"
```
