//go:build !windows

package main

import (
	"io"
	"os"
	"os/exec"

	"github.com/creack/pty"
	"golang.org/x/crypto/ssh"
)

// runShell executes a command (or an interactive shell when command == "")
// attached to the SSH channel. With a PTY requested it allocates one.
func runShell(channel ssh.Channel, command string, opts *shellOpts) int {
	var cmd *exec.Cmd
	if command == "" {
		shell := os.Getenv("SHELL")
		if shell == "" {
			shell = "/bin/sh"
		}
		cmd = exec.Command(shell)
	} else {
		cmd = exec.Command("/bin/sh", "-c", command)
	}
	if opts != nil && opts.pty {
		ws := &pty.Winsize{Cols: uint16(orDefault(opts.cols, 80)), Rows: uint16(orDefault(opts.rows, 24))}
		f, err := pty.StartWithSize(cmd, ws)
		if err == nil {
			defer f.Close()
			go func() {
				for sz := range opts.winCh {
					_ = pty.Setsize(f, &pty.Winsize{Cols: uint16(sz[0]), Rows: uint16(sz[1])})
				}
			}()
			go func() { _, _ = io.Copy(f, channel) }()
			_, _ = io.Copy(channel, f)
			if err := cmd.Wait(); err != nil {
				if ee, ok := err.(*exec.ExitError); ok {
					return ee.ExitCode()
				}
				return 1
			}
			return 0
		}
		// fall through to pipe mode if PTY allocation failed
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

func orDefault(v, d int) int {
	if v <= 0 {
		return d
	}
	return v
}
