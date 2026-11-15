//go:build linux

package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

func tunName() string {
	if n := os.Getenv("MESHPC_TUN"); n != "" {
		return n
	}
	return "mesh0"
}

func runCmd(name string, args ...string) error {
	out, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s: %v: %s", name, strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

func osAssignIP(iface, vip string) error {
	if err := runCmd("ip", "addr", "add", vip+"/24", "dev", iface); err != nil {
		return err
	}
	return runCmd("ip", "link", "set", iface, "up")
}

func defaultRoute() (gw, iface string, err error) {
	out, err := exec.Command("ip", "route", "show", "default").Output()
	if err != nil {
		return "", "", err
	}
	fields := strings.Fields(string(out))
	for i, f := range fields {
		if f == "via" && i+1 < len(fields) {
			gw = fields[i+1]
		}
		if f == "dev" && i+1 < len(fields) {
			iface = fields[i+1]
		}
	}
	if gw == "" || iface == "" {
		return "", "", fmt.Errorf("no default route found")
	}
	return gw, iface, nil
}

func osAddExitRoutes(tunIface, hubEndpoint string) error {
	gw, physIface, err := defaultRoute()
	if err != nil {
		return err
	}
	hubIP, err := resolveHostIP(hubEndpoint)
	if err != nil {
		return err
	}
	if err := runCmd("ip", "route", "add", hubIP+"/32", "via", gw, "dev", physIface); err != nil {
		return err
	}
	if err := runCmd("ip", "route", "add", "0.0.0.0/1", "dev", tunIface); err != nil {
		return err
	}
	return runCmd("ip", "route", "add", "128.0.0.0/1", "dev", tunIface)
}

func osRemoveExitRoutes(tunIface, hubEndpoint string) {
	_ = runCmd("ip", "route", "del", "0.0.0.0/1", "dev", tunIface)
	_ = runCmd("ip", "route", "del", "128.0.0.0/1", "dev", tunIface)
	if gw, physIface, err := defaultRoute(); err == nil {
		if hubIP, err := resolveHostIP(hubEndpoint); err == nil {
			_ = runCmd("ip", "route", "del", hubIP+"/32", "via", gw, "dev", physIface)
		}
	}
}

func osEnableExitNAT() error {
	_, iface, err := defaultRoute()
	if err != nil {
		return err
	}
	if err := runCmd("sysctl", "-w", "net.ipv4.ip_forward=1"); err != nil {
		return err
	}
	if err := runCmd("iptables", "-t", "nat", "-A", "POSTROUTING", "-s", "10.99.0.0/24", "-o", iface, "-j", "MASQUERADE"); err != nil {
		return err
	}
	_ = runCmd("iptables", "-A", "FORWARD", "-s", "10.99.0.0/24", "-j", "ACCEPT")
	_ = runCmd("iptables", "-A", "FORWARD", "-d", "10.99.0.0/24", "-m", "state", "--state", "RELATED,ESTABLISHED", "-j", "ACCEPT")
	return nil
}

func osDisableExitNAT() {
	_, iface, err := defaultRoute()
	if err != nil {
		return
	}
	_ = runCmd("iptables", "-t", "nat", "-D", "POSTROUTING", "-s", "10.99.0.0/24", "-o", iface, "-j", "MASQUERADE")
	_ = runCmd("iptables", "-D", "FORWARD", "-s", "10.99.0.0/24", "-j", "ACCEPT")
	_ = runCmd("iptables", "-D", "FORWARD", "-d", "10.99.0.0/24", "-m", "state", "--state", "RELATED,ESTABLISHED", "-j", "ACCEPT")
}
