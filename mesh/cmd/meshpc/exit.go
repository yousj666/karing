package main

import (
	"fmt"

	"yousj-mesh/internal/client"
)

func cmdExit(args []string) {
	if len(args) < 1 {
		fatal(fmt.Errorf("usage: meshpc exit <offer on|off | use <peer|off> | status>"))
	}
	c := load()
	n := mustActive(c)
	switch args[0] {
	case "offer":
		if len(args) < 2 || (args[1] != "on" && args[1] != "off") {
			fatal(fmt.Errorf("usage: meshpc exit offer on|off"))
		}
		n.ExitOffering = args[1] == "on"
		n.ExitCapable = true
		if err := c.Save(); err != nil {
			fatal(err)
		}
		if err := c.Heartbeat(n); err != nil {
			fatal(fmt.Errorf("saved locally; coordinator heartbeat failed: %w", err))
		}
		fmt.Printf("exit offering: %v (daemon reconciles within ~30s if running)\n", n.ExitOffering)
	case "use":
		if len(args) < 2 {
			fatal(fmt.Errorf("usage: meshpc exit use <peer|off>"))
		}
		if args[1] == "off" {
			n.ExitChoice = ""
		} else {
			m, err := resolvePeer(c, n, args[1])
			if err != nil {
				fatal(err)
			}
			if m.DeviceID == c.DeviceID() {
				fatal(fmt.Errorf("cannot use this device as its own exit"))
			}
			if !m.ExitOffering {
				fatal(fmt.Errorf("%s is not currently offering exit (it must run `meshpc exit offer on`)", m.Name))
			}
			n.ExitChoice = m.DeviceID
		}
		if err := c.Save(); err != nil {
			fatal(err)
		}
		if err := c.Heartbeat(n); err != nil {
			fatal(fmt.Errorf("saved locally; coordinator heartbeat failed: %w", err))
		}
		fmt.Printf("exit choice: %s (daemon reconciles within ~30s if running)\n", orNone(n.ExitChoice))
	case "status":
		fmt.Printf("exit capable: %v\nexit offering: %v\nexit choice: %s\n", n.ExitCapable, n.ExitOffering, orNone(n.ExitChoice))
	default:
		fatal(fmt.Errorf("usage: meshpc exit <offer on|off | use <peer|off> | status>"))
	}
}

func cmdSSHServer(args []string) {
	if len(args) < 1 {
		fatal(fmt.Errorf("usage: meshpc ssh-server <on|off|status> [--share DIR]"))
	}
	c := load()
	switch args[0] {
	case "on":
		c.State.SSHServer = true
		for i, a := range args {
			if a == "--share" && i+1 < len(args) {
				c.State.SSHShare = args[i+1]
			}
		}
		if err := c.Save(); err != nil {
			fatal(err)
		}
		fmt.Println("ssh/sftp server: enabled (starts with `meshpc up`; binds the mesh VIP only)")
	case "off":
		c.State.SSHServer = false
		if err := c.Save(); err != nil {
			fatal(err)
		}
		fmt.Println("ssh/sftp server: disabled (takes effect on next `meshpc up`)")
	case "status":
		fmt.Printf("ssh/sftp server: enabled=%v share=%s\n", c.State.SSHServer, orHome(c.State.SSHShare))
	default:
		fatal(fmt.Errorf("usage: meshpc ssh-server <on|off|status>"))
	}
}

var _ = client.Load
