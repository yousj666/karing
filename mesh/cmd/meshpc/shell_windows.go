//go:build windows

package main

import (
	"os/exec"

	"golang.org/x/crypto/ssh"
)

// runShell on Windows: cmd.exe via pipes (no ConPTY in phase 1; interactive
// use still works line-wise, exec and SFTP are fully functional).
func runShell(channel ssh.Channel, command string, opts *shellOpts) int {
	var cmd *exec.Cmd
	if command == "" {
		cmd = exec.Command("cmd.exe")
	} else {
		cmd = exec.Command("cmd.exe", "/C", command)
	}
	cmd.Stdin = channel
	cmd.Stdout = channel
	cmd.Stderr = channel.Stderr()
	if err := cmd.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return ee.ExitCode()
		}
		return 1
	}
	return 0
}
