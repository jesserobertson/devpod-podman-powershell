package main

import (
	_ "embed"
	"os"
	"os/exec"
	"path/filepath"
)

//go:embed ../../scripts/init.ps1
var initScript string

func main() {
	tmp := filepath.Join(os.TempDir(), "devpod-podman-init.ps1")
	if err := os.WriteFile(tmp, []byte(initScript), 0644); err != nil {
		os.Stderr.WriteString("failed to write init script: " + err.Error() + "\n")
		os.Exit(1)
	}
	defer os.Remove(tmp)

	cmd := exec.Command("pwsh", "-NonInteractive", "-NoProfile", "-File", tmp)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = os.Environ()
	if err := cmd.Run(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			os.Exit(exitErr.ExitCode())
		}
		os.Exit(1)
	}
}
