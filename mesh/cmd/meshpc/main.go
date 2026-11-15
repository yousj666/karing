// yousj-mesh-pc: the PC client for Yousj Mesh (phase 1: CLI).
//
// Commands:
//   meshpc create  --coordinator URL --name NET --device NAME
//   meshpc invite  [--ttl HOURS] [--uses N]        (creator only; prints payload)
//   meshpc join    --payload 'yousjmesh://...' --device NAME
//   meshpc networks | use <network-id>
//   meshpc status | peers
//   meshpc up | down                               (tunnel daemon)
//   meshpc exit    offer on|off | use <device|off> | status
//   meshpc ssh-server on|off|status
//   meshpc ssh     <peer-name|vip> [-- cmd...]
//   meshpc put     <local> <peer>:<remote>
//   meshpc get     <peer>:<remote> <local>
//   meshpc kick <device-id> | dissolve | leave
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"yousj-mesh/internal/client"
	"yousj-mesh/internal/proto"
)

func dataDir() string {
	if d := os.Getenv("MESHPC_HOME"); d != "" {
		return d
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".yousj-mesh")
}

func load() *client.Client {
	c, err := client.Load(dataDir())
	if err != nil {
		fatal(err)
	}
	return c
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "create":
		cmdCreate(os.Args[2:])
	case "invite":
		cmdInvite(os.Args[2:])
	case "join":
		cmdJoin(os.Args[2:])
	case "networks":
		c := load()
		for _, n := range c.State.Networks {
			mark := " "
			if n.ID == c.State.ActiveID {
				mark = "*"
			}
			fmt.Printf("%s %s  %s  vip=%s coord=%s\n", mark, n.ID, n.Name, n.VIP, n.Coordinator)
		}
	case "use":
		if len(os.Args) < 3 {
			fatal(fmt.Errorf("usage: meshpc use <network-id>"))
		}
		c := load()
		if c.State.Networks[os.Args[2]] == nil {
			fatal(fmt.Errorf("no such network"))
		}
		c.State.ActiveID = os.Args[2]
		if err := c.Save(); err != nil {
			fatal(err)
		}
		fmt.Println("active network:", os.Args[2])
	case "status":
		cmdStatus()
	case "peers":
		cmdPeers()
	case "up":
		cmdUp()
	case "down":
		cmdDown()
	case "exit":
		cmdExit(os.Args[2:])
	case "ssh-server":
		cmdSSHServer(os.Args[2:])
	case "ssh":
		cmdSSH(os.Args[2:])
	case "put":
		cmdPutGet(os.Args[2:], true)
	case "get":
		cmdPutGet(os.Args[2:], false)
	case "kick":
		if len(os.Args) < 3 {
			fatal(fmt.Errorf("usage: meshpc kick <device-id>"))
		}
		c := load()
		n := mustActive(c)
		if err := c.Kick(n, os.Args[2]); err != nil {
			fatal(err)
		}
		fmt.Println("kicked:", os.Args[2])
	case "dissolve":
		c := load()
		n := mustActive(c)
		if err := c.Dissolve(n); err != nil {
			fatal(err)
		}
		fmt.Println("network dissolved:", n.Name)
	case "leave":
		c := load()
		n := mustActive(c)
		if err := c.Leave(n); err != nil {
			fatal(err)
		}
		fmt.Println("left network:", n.Name)
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: meshpc <create|invite|join|networks|use|status|peers|up|down|exit|ssh-server|ssh|put|get|kick|dissolve|leave>")
}

func mustActive(c *client.Client) *client.Network {
	n := c.Active()
	if n == nil {
		fatal(fmt.Errorf("no active network (create or join first)"))
	}
	return n
}

func cmdCreate(args []string) {
	fs := flag.NewFlagSet("create", flag.ExitOnError)
	coord := fs.String("coordinator", "", "coordinator base URL, e.g. https://1.2.3.4:18790")
	name := fs.String("name", "", "network name")
	device := fs.String("device", "", "this device's display name")
	_ = fs.Parse(args)
	if *coord == "" || *name == "" || *device == "" {
		fatal(fmt.Errorf("--coordinator, --name and --device are required"))
	}
	c := load()
	n, _, err := c.CreateNetwork(*coord, *name)
	if err != nil {
		fatal(err)
	}
	// The creator joins its own network through a self-invite so the flow is
	// identical for every member.
	inv, err := c.CreateInvite(n, 3600, 1)
	if err != nil {
		fatal(err)
	}
	payload, err := c.InvitePayload(n, inv.Code)
	if err != nil {
		fatal(err)
	}
	joined, err := c.Join(payload, *device)
	if err != nil {
		fatal(err)
	}
	fmt.Printf("network created: %s (%s)\n", joined.Name, joined.ID)
	fmt.Printf("this device: %s vip=%s\n", joined.DeviceID, joined.VIP)
	fmt.Println("admin token saved locally (creator only). Use `meshpc invite` to add devices.")
}

func cmdInvite(args []string) {
	fs := flag.NewFlagSet("invite", flag.ExitOnError)
	ttl := fs.Int("ttl", 24, "invite lifetime in hours")
	uses := fs.Int("uses", 1, "max uses")
	_ = fs.Parse(args)
	c := load()
	n := mustActive(c)
	if n.AdminToken == "" {
		fatal(fmt.Errorf("only the network creator can mint invites"))
	}
	inv, err := c.CreateInvite(n, *ttl*3600, *uses)
	if err != nil {
		fatal(err)
	}
	payload, err := c.InvitePayload(n, inv.Code)
	if err != nil {
		fatal(err)
	}
	fmt.Println(payload)
	fmt.Fprintf(os.Stderr, "expires: %s\n", time.Unix(inv.ExpiresAt, 0).Format(time.RFC3339))
}

func cmdJoin(args []string) {
	fs := flag.NewFlagSet("join", flag.ExitOnError)
	payload := fs.String("payload", "", "invite payload (yousjmesh://join?d=...)")
	device := fs.String("device", "", "this device's display name")
	_ = fs.Parse(args)
	if *payload == "" || *device == "" {
		fatal(fmt.Errorf("--payload and --device are required"))
	}
	c := load()
	n, err := c.Join(*payload, *device)
	if err != nil {
		fatal(err)
	}
	fmt.Printf("joined network: %s (%s)\nthis device: %s vip=%s hub=%s\n", n.Name, n.ID, n.DeviceID, n.VIP, n.HubEndpoint)
}

func cmdStatus() {
	c := load()
	fmt.Printf("device id: %s\n", c.DeviceID())
	n := c.Active()
	if n == nil {
		fmt.Println("no active network")
		return
	}
	fmt.Printf("network: %s (%s) via %s\nvip: %s\nhub: %s\n", n.Name, n.ID, n.Coordinator, n.VIP, n.HubEndpoint)
	fmt.Printf("exit: offering=%v choice=%s\n", n.ExitOffering, orNone(n.ExitChoice))
	fmt.Printf("ssh server: %v (port %d, share=%s)\n", c.State.SSHServer, proto.SSHPort, orHome(c.State.SSHShare))
	if st := readDaemonStatus(); st != "" {
		fmt.Println("daemon:", st)
	} else {
		fmt.Println("daemon: not running")
	}
}

func cmdPeers() {
	c := load()
	n := mustActive(c)
	resp, err := c.Members(n)
	if err != nil {
		fatal(err)
	}
	for _, m := range resp.Members {
		self := ""
		if m.DeviceID == c.DeviceID() {
			self = " (this device)"
		}
		exit := ""
		if m.ExitOffering {
			exit = " [exit offered]"
		} else if m.ExitCapable {
			exit = " [exit capable]"
		}
		online := "offline"
		if m.Online {
			online = "online"
		}
		fmt.Printf("%-16s %-15s %-8s %s%s%s\n", m.Name, m.VIP, online, m.DeviceID, exit, self)
	}
}

func orNone(s string) string {
	if s == "" {
		return "none"
	}
	return s
}

func orHome(s string) string {
	if s == "" {
		return "home dir"
	}
	return s
}

var _ = strings.TrimSpace
