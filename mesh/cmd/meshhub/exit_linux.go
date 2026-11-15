//go:build linux

package main

import (
	"crypto/tls"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"sort"
	"strings"
)

func insecureTransport() http.RoundTripper {
	return &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}} //nolint:gosec // operator-chosen for self-signed meshd
}

func assignAddr(iface, cidr string) error {
	if err := runIP("addr", "add", cidr, "dev", iface); err != nil {
		return err
	}
	return runIP("link", "set", iface, "up")
}

func runIP(args ...string) error {
	out, err := exec.Command("ip", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("ip %s: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

// reconcileExitRules installs one policy-routing table per member that has
// chosen an exit: traffic from that member defaults via the exit member's
// virtual IP on the hub interface. Rules live at priority 20000+. The
// desired set is diffed against the last applied set so steady-state polls
// do not flap the rules.
var lastExitSig string

func reconcileExitRules(peers []hubPeer) {
	vipByDevice := map[string]string{}
	for _, p := range peers {
		vipByDevice[p.DeviceID] = p.VIP
	}
	type rule struct{ from, via string }
	desired := []rule{}
	for _, p := range peers {
		if p.ExitChoice == "" {
			continue
		}
		exitVIP, ok := vipByDevice[p.ExitChoice]
		if !ok || exitVIP == p.VIP {
			continue
		}
		desired = append(desired, rule{from: p.VIP, via: exitVIP})
	}
	sort.Slice(desired, func(i, j int) bool { return desired[i].from < desired[j].from })
	sig := fmt.Sprint(desired)
	if sig == lastExitSig {
		return
	}
	// Rebuild our priority range.
	for pr := 20000; pr < 20010; pr++ {
		for {
			if err := exec.Command("ip", "rule", "del", "priority", fmt.Sprint(pr)).Run(); err != nil {
				break
			}
		}
	}
	pr := 20000
	for _, r := range desired {
		oct := 0
		fmt.Sscanf(r.from, "10.99.0.%d", &oct)
		table := 1000 + oct
		_ = exec.Command("ip", "route", "replace", "default", "via", r.via, "dev", hubIfaceName(), "table", fmt.Sprint(table)).Run()
		_ = exec.Command("ip", "rule", "add", "from", r.from, "table", fmt.Sprint(table), "priority", fmt.Sprint(pr)).Run()
		pr++
		if pr >= 20010 {
			break
		}
	}
	lastExitSig = sig
}

// ensureForwardRule makes sure member-to-member forwarding through the hub
// interface is allowed. Hosts running Docker default the FORWARD chain to
// DROP, which silently breaks hub relaying; insert an ACCEPT for
// hub-interface traffic at the top of the chain (idempotent).
func ensureForwardRule(iface string) {
	check := exec.Command("iptables", "-C", "FORWARD", "-i", iface, "-o", iface, "-j", "ACCEPT")
	if check.Run() == nil {
		return
	}
	if err := exec.Command("iptables", "-I", "FORWARD", "1", "-i", iface, "-o", iface, "-j", "ACCEPT").Run(); err != nil {
		fmt.Fprintf(os.Stderr, "meshhub: warning: could not add FORWARD accept rule for %s: %v\n", iface, err)
	}
}

var ifaceNameCache string

func hubIfaceName() string {
	if ifaceNameCache != "" {
		return ifaceNameCache
	}
	ifaceNameCache = *flagIface
	return ifaceNameCache
}
