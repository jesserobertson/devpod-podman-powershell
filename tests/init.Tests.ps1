#Requires -Module Pester

BeforeAll {
    $script:InitScript = (Resolve-Path "$PSScriptRoot\..\scripts\init.ps1").Path
    $script:MocksDir   = (Resolve-Path "$PSScriptRoot\mocks").Path

    function Invoke-Init {
        param([hashtable]$Env = @{})

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
        foreach ($k in $Env.Keys) { $defaults[$k] = $Env[$k] }

        # Set env vars in current process — child pwsh inherits them
        foreach ($k in $defaults.Keys) {
            [System.Environment]::SetEnvironmentVariable($k, $defaults[$k])
        }

        $output = pwsh -NonInteractive -NoProfile -File $script:InitScript 2>&1
        [pscustomobject]@{
            Output   = $output
            ExitCode = $LASTEXITCODE
            Text     = ($output -join "`n")
        }
    }
}

Describe 'init.ps1' {

    Context 'running machine, config matches defaults' {
        It 'exits 0 and prints success' {
            $result = Invoke-Init @{
                PODMAN_PATH = (Join-Path $script:MocksDir 'podman-running.ps1')
            }
            $result.ExitCode | Should -Be 0
            $result.Output   | Should -Contain 'Podman provider initialized successfully.'
        }

        It 'reports the machine as already running' {
            $result = Invoke-Init @{
                PODMAN_PATH = (Join-Path $script:MocksDir 'podman-running.ps1')
            }
            $result.Text | Should -Match 'already running'
        }
    }

    Context 'stopped machine, AUTO_START=true' {
        It 'starts the machine and exits 0' {
            $result = Invoke-Init @{
                PODMAN_PATH               = (Join-Path $script:MocksDir 'podman-stopped.ps1')
                PODMAN_MACHINE_AUTO_START = 'true'
            }
            $result.ExitCode | Should -Be 0
            $result.Text     | Should -Match 'Starting machine'
            $result.Output   | Should -Contain 'Podman provider initialized successfully.'
        }
    }

    Context 'stopped machine, AUTO_START=false' {
        It 'exits 1 with an error message' {
            $result = Invoke-Init @{
                PODMAN_PATH               = (Join-Path $script:MocksDir 'podman-stopped.ps1')
                PODMAN_MACHINE_AUTO_START = 'false'
            }
            $result.ExitCode | Should -Be 1
            $result.Text     | Should -Match 'is not running'
        }
    }

    Context 'no machine exists, AUTO_INIT=false' {
        It 'exits 1 with instructions to create a machine' {
            $result = Invoke-Init @{
                PODMAN_PATH              = (Join-Path $script:MocksDir 'podman-no-machine.ps1')
                PODMAN_MACHINE_AUTO_INIT = 'false'
            }
            $result.ExitCode | Should -Be 1
            $result.Text     | Should -Match 'No Podman machine found'
        }
    }

    Context 'no machine exists, AUTO_INIT=true' {
        It 'creates devpod-machine, starts it, and exits 0' {
            $result = Invoke-Init @{
                PODMAN_PATH              = (Join-Path $script:MocksDir 'podman-no-machine.ps1')
                PODMAN_MACHINE_AUTO_INIT  = 'true'
                PODMAN_MACHINE_AUTO_START = 'true'
            }
            $result.ExitCode | Should -Be 0
            $result.Text     | Should -Match "Creating 'devpod-machine'"
            $result.Text     | Should -Match 'created successfully'
            $result.Output   | Should -Contain 'Podman provider initialized successfully.'
        }
    }

    Context 'running machine, resource mismatch, AUTO_RESOURCE_UPDATE=false' {
        It 'warns about mismatch and exits 0' {
            $result = Invoke-Init @{
                PODMAN_PATH                         = (Join-Path $script:MocksDir 'podman-mismatch.ps1')
                PODMAN_MACHINE_AUTO_RESOURCE_UPDATE = 'false'
                PODMAN_MACHINE_CPUS                 = '2'
                PODMAN_MACHINE_MEMORY               = '4096'
            }
            $result.ExitCode | Should -Be 0
            $result.Text     | Should -Match 'mismatch'
            $result.Text     | Should -Match 'Continuing with existing configuration'
            $result.Output   | Should -Contain 'Podman provider initialized successfully.'
        }
    }

    Context 'running machine, resource mismatch, AUTO_RESOURCE_UPDATE=true' {
        It 'stops, applies CPU and memory changes, restarts, and exits 0' {
            $result = Invoke-Init @{
                PODMAN_PATH                         = (Join-Path $script:MocksDir 'podman-mismatch.ps1')
                PODMAN_MACHINE_AUTO_RESOURCE_UPDATE = 'true'
                PODMAN_MACHINE_CPUS                 = '2'
                PODMAN_MACHINE_MEMORY               = '4096'
            }
            $result.ExitCode | Should -Be 0
            $result.Text     | Should -Match 'Stopping'
            $result.Text     | Should -Match 'Setting CPUs'
            $result.Text     | Should -Match 'Setting memory'
            $result.Text     | Should -Match 'Resource update complete'
            $result.Output   | Should -Contain 'Podman provider initialized successfully.'
        }
    }

    Context 'disk shrink requested, AUTO_RESOURCE_UPDATE=true' {
        It 'warns that disk cannot shrink, skips disk update, and exits 0' {
            $result = Invoke-Init @{
                PODMAN_PATH                         = (Join-Path $script:MocksDir 'podman-running.ps1')
                PODMAN_MACHINE_AUTO_RESOURCE_UPDATE = 'true'
                PODMAN_MACHINE_DISK_SIZE            = '50'
            }
            $result.ExitCode | Should -Be 0
            $result.Text     | Should -Match 'disk shrink'
            $result.Output   | Should -Contain 'Podman provider initialized successfully.'
        }
    }

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
}
