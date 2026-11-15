package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"

	"yousj-mesh/internal/client"
	"yousj-mesh/internal/proto"
)

type daemonStatus struct {
	PID   int    `json:"pid"`
	Since int64  `json:"since"`
	VIP   string `json:"vip"`
	Iface string `json:"iface"`
}

func daemonStatusPath() string { return filepath.Join(dataDir(), "daemon.json") }

func writeDaemonStatus(st daemonStatus) {
	b, _ := json.Marshal(st)
	_ = os.WriteFile(daemonStatusPath(), b, 0o600)
}

func readDaemonStatus() string {
	b, err := os.ReadFile(daemonStatusPath())
	if err != nil {
		return ""
	}
	var st daemonStatus
	if json.Unmarshal(b, &st) != nil {
		return ""
	}
	if proc, err := os.FindProcess(st.PID); err != nil || proc == nil {
		return ""
	}
	return fmt.Sprintf("running pid=%d since %s vip=%s iface=%s",
		st.PID, time.Unix(st.Since, 0).Format("15:04:05"), st.VIP, st.Iface)
}

func b64ToHex(b64 string) (string, error) {
	raw, err := proto.B64.DecodeString(b64)
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(raw), nil
}

// buildUAPI renders the wireguard-go IPC config. Phase 1 is hub-and-spoke:
// the single data-plane peer is the hub; the member list drives the hub's
// own peer table, SSH authorization and exit selection.
func buildUAPI(c *client.Client, n *client.Network) (string, error) {
	privHex, err := b64ToHex(c.State.Identity.WGPriv)
	if err != nil {
		return "", err
	}
	hubHex, err := b64ToHex(n.HubPub)
	if err != nil {
		return "", fmt.Errorf("hub public key: %w", err)
	}
	pskHex, err := b64ToHex(n.PSK)
	if err != nil {
		return "", fmt.Errorf("network psk: %w", err)
	}
	allowed := proto.Subnet
	if n.ExitChoice != "" {
		allowed = "0.0.0.0/0"
	}
	var sb strings.Builder
	fmt.Fprintf(&sb, "private_key=%s\n", privHex)
	sb.WriteString("replace_peers=true\n")
	fmt.Fprintf(&sb, "public_key=%s\n", hubHex)
	fmt.Fprintf(&sb, "preshared_key=%s\n", pskHex)
	fmt.Fprintf(&sb, "endpoint=%s\n", n.HubEndpoint)
	fmt.Fprintf(&sb, "allowed_ip=%s\n", allowed)
	sb.WriteString("persistent_keepalive_interval=25\n")
	return sb.String(), nil
}

func cmdUp() {
	c := load()
	n := mustActive(c)
	if st := readDaemonStatus(); st != "" {
		fatal(fmt.Errorf("daemon already running (%s); run `meshpc down` first", st))
	}
	if _, err := c.Members(n); err != nil {
		fatal(fmt.Errorf("coordinator unreachable or membership invalid: %w", err))
	}

	ifaceName := tunName()
	tunDev, err := tun.CreateTUN(ifaceName, device.DefaultMTU)
	if err != nil {
		fatal(fmt.Errorf("create tun (need admin/root + wintun.dll on Windows): %w", err))
	}
	logger := device.NewLogger(device.LogLevelError, "mesh: ")
	dev := device.NewDevice(tunDev, conn.NewDefaultBind(), logger)
	uapi, err := buildUAPI(c, n)
	if err != nil {
		fatal(err)
	}
	if err := dev.IpcSet(uapi); err != nil {
		fatal(fmt.Errorf("configure wireguard: %w", err))
	}
	if err := dev.Up(); err != nil {
		fatal(fmt.Errorf("bring wireguard up: %w", err))
	}
	realName, err := tunDev.Name()
	if err != nil {
		realName = ifaceName
	}
	if err := osAssignIP(realName, n.VIP); err != nil {
		fatal(fmt.Errorf("assign %s to %s: %w", n.VIP, realName, err))
	}
	exitRoutesOn := false
	if n.ExitChoice != "" {
		if err := osAddExitRoutes(realName, n.HubEndpoint); err != nil {
			fmt.Fprintln(os.Stderr, "warning: exit routes failed:", err)
		} else {
			exitRoutesOn = true
		}
	}
	natOn := false
	if n.ExitOffering {
		if err := osEnableExitNAT(); err != nil {
			fmt.Fprintln(os.Stderr, "warning: exit NAT failed (need admin/root):", err)
		} else {
			natOn = true
		}
	}

	var sshSrv *sshServer
	if c.State.SSHServer {
		sshSrv, err = startSSHServer(c, n)
		if err != nil {
			fmt.Fprintln(os.Stderr, "warning: ssh server failed:", err)
		} else {
			fmt.Printf("ssh/sftp server listening on %s:%d\n", n.VIP, proto.SSHPort)
		}
	}

	writeDaemonStatus(daemonStatus{PID: os.Getpid(), Since: time.Now().Unix(), VIP: n.VIP, Iface: realName})
	fmt.Printf("mesh up: %s vip=%s iface=%s hub=%s exit_choice=%s exit_offering=%v\n",
		n.Name, n.VIP, realName, n.HubEndpoint, orNone(n.ExitChoice), n.ExitOffering)

	// Supervision loop: heartbeat + member refresh; re-render on changes.
	sig := make(chan os.Signal, 2)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	tick := time.NewTicker(30 * time.Second)
	defer tick.Stop()
	lastUAPI := uapi
loop:
	for {
		select {
		case <-sig:
			break loop
		case <-tick.C:
			if err := c.Reload(); err != nil {
				fmt.Fprintln(os.Stderr, "warning: state reload failed:", err)
			}
			nn := c.State.Networks[n.ID]
			if nn == nil {
				break loop // left/dissolved locally
			}
			n = nn
			_ = c.Heartbeat(nn)
			if _, err := c.Members(nn); err != nil {
				fmt.Fprintln(os.Stderr, "warning: member refresh failed:", err)
				continue
			}
			newUAPI, err := buildUAPI(c, nn)
			if err == nil && newUAPI != lastUAPI {
				if err := dev.IpcSet(newUAPI); err == nil {
					lastUAPI = newUAPI
					fmt.Println("mesh: tunnel config refreshed (hub/exit changed)")
				}
			}
			// Exit offering toggled while running: reconcile NAT.
			if nn.ExitOffering && !natOn {
				if err := osEnableExitNAT(); err == nil {
					natOn = true
				}
			} else if !nn.ExitOffering && natOn {
				osDisableExitNAT()
				natOn = false
			}
			// Exit choice toggled while running: reconcile OS routes.
			if nn.ExitChoice != "" && !exitRoutesOn {
				if err := osAddExitRoutes(realName, nn.HubEndpoint); err == nil {
					exitRoutesOn = true
				}
			} else if nn.ExitChoice == "" && exitRoutesOn {
				osRemoveExitRoutes(realName, nn.HubEndpoint)
				exitRoutesOn = false
			}
		}
	}

	fmt.Println("mesh: shutting down")
	if sshSrv != nil {
		sshSrv.Close()
	}
	if exitRoutesOn {
		osRemoveExitRoutes(realName, n.HubEndpoint)
	}
	if natOn {
		osDisableExitNAT()
	}
	dev.Down()
	_ = os.Remove(daemonStatusPath())
}

func cmdDown() {
	b, err := os.ReadFile(daemonStatusPath())
	if err != nil {
		fatal(fmt.Errorf("daemon not running"))
	}
	var st daemonStatus
	if json.Unmarshal(b, &st) != nil {
		fatal(fmt.Errorf("daemon status corrupt"))
	}
	proc, err := os.FindProcess(st.PID)
	if err != nil {
		fatal(err)
	}
	if err := proc.Signal(os.Interrupt); err != nil {
		// Fall back to kill.
		if err := proc.Kill(); err != nil {
			fatal(fmt.Errorf("stop daemon: %w", err))
		}
	}
	for i := 0; i < 20; i++ {
		time.Sleep(250 * time.Millisecond)
		if _, err := os.Stat(daemonStatusPath()); os.IsNotExist(err) {
			fmt.Println("daemon stopped")
			return
		}
	}
	_ = proc.Kill()
	_ = os.Remove(daemonStatusPath())
	fmt.Println("daemon stopped (forced)")
}

// resolveHostIP resolves a host:port endpoint to its IP (for the /32 host
// route that keeps hub traffic out of the tunnel when exit routing is on).
func resolveHostIP(endpoint string) (string, error) {
	host, _, err := net.SplitHostPort(endpoint)
	if err != nil {
		return "", err
	}
	if ip := net.ParseIP(host); ip != nil {
		return host, nil
	}
	ips, err := net.LookupIP(host)
	if err != nil || len(ips) == 0 {
		return "", fmt.Errorf("resolve %s: %w", host, err)
	}
	return ips[0].String(), nil
}
