# Mock podman: one machine named 'test-machine', stopped
param()

switch ($args[0]) {
    '--version' { Write-Output 'podman version 5.0.0'; exit 0 }
    'machine' {
        switch ($args[1]) {
            'list' {
                Write-Output '[{"Name":"test-machine","Running":false}]'
                exit 0
            }
            'inspect' {
                Write-Output '[{"Name":"test-machine","State":"stopped","Resources":{"CPUs":2,"Memory":4096,"DiskSize":100},"Rootful":false}]'
                exit 0
            }
            'start' {
                # After start, ps will succeed (same process, but we just exit 0 here)
                exit 0
            }
            'stop'  { exit 0 }
            'set'   { exit 0 }
        }
    }
    'ps' { exit 0 }
    default { exit 1 }
}
