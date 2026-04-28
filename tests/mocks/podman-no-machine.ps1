# Mock podman: no machines exist
param()

switch ($args[0]) {
    '--version' { Write-Output 'podman version 5.0.0'; exit 0 }
    'machine' {
        switch ($args[1]) {
            'list'   { Write-Output '[]'; exit 0 }
            'init'   { Write-Output 'Machine init called'; exit 0 }
            'start'  { exit 0 }
            'inspect' {
                Write-Output '[{"Name":"devpod-machine","State":"stopped","Resources":{"CPUs":2,"Memory":4096,"DiskSize":100},"Rootful":false}]'
                exit 0
            }
        }
    }
    'ps' { exit 0 }
    default { exit 1 }
}
