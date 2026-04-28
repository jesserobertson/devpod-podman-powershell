[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ── 1. Resolve podman binary ──────────────────────────────────────────────────
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

# ── 2. Print version ──────────────────────────────────────────────────────────
$versionOutput = & $podmanExe --version
Write-Host "Found $versionOutput"

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

    # ── 6a. Resource mismatch — detect ───────────────────────────────────────
    $currentCpus     = $inspect.Resources.CPUs
    $currentMemoryMb = $inspect.Resources.Memory
    $currentDiskGb   = $inspect.Resources.DiskSize
    $currentRootful  = [bool]$inspect.Rootful

    $desiredCpus     = [int]$env:PODMAN_MACHINE_CPUS
    $desiredMemoryMb = [int]$env:PODMAN_MACHINE_MEMORY
    $desiredDiskGb   = [int]$env:PODMAN_MACHINE_DISK_SIZE
    $desiredRootful  = ($env:PODMAN_MACHINE_ROOTFUL -eq 'true')

    $mismatches = @()
    if ($currentCpus     -ne $desiredCpus)     { $mismatches += "  CPUs:    current=$currentCpus  desired=$desiredCpus" }
    if ($currentMemoryMb -ne $desiredMemoryMb)  { $mismatches += "  Memory:  current=${currentMemoryMb}MB  desired=${desiredMemoryMb}MB" }
    if ($currentDiskGb   -ne $desiredDiskGb)    { $mismatches += "  Disk:    current=${currentDiskGb}GB  desired=${desiredDiskGb}GB" }
    if ($currentRootful  -ne $desiredRootful)   { $mismatches += "  Rootful: current=$currentRootful  desired=$desiredRootful" }

    if ($mismatches.Count -gt 0) {
        if ($env:PODMAN_MACHINE_AUTO_RESOURCE_UPDATE -eq 'true') {

            # ── 6b. Resource auto-update ──────────────────────────────────────
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

        }
        else {
            # ── 6c. Warn and continue ─────────────────────────────────────────
            Write-Warning "Resource configuration mismatch detected for '$machineName':"
            $mismatches | ForEach-Object { Write-Warning $_ }
            Write-Warning ""
            Write-Warning ("To apply in-place: " +
                           "devpod provider set-options podman-windows PODMAN_MACHINE_AUTO_RESOURCE_UPDATE=true")
            Write-Warning "Continuing with existing configuration..."
        }
    }
}

# ── 6d. NVIDIA GPU setup (SSH) ───────────────────────────────────────────────
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

# ── 7. Connectivity check ─────────────────────────────────────────────────────
Write-Host "Testing Podman connectivity..."
$null = & $podmanExe ps 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error ("Podman is not reachable. " +
                 "Check machine status with: podman machine list")
    exit 1
}

Write-Host "Podman provider initialized successfully."
