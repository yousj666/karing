//go:build windows

package main

import (
	"fmt"
	"os/exec"
	"strings"
)

func tunName() string { return "YousjMesh" }

func runCmd(name string, args ...string) error {
	out, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s: %v: %s", name, strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

func osAssignIP(iface, vip string) error {
	return runCmd("netsh", "interface", "ipv4", "set", "address", "name="+iface, "static", vip, "255.255.255.0")
}

func osAddExitRoutes(tunIface, hubEndpoint string) error {
	hubIP, err := resolveHostIP(hubEndpoint)
	if err != nil {
		return err
	}
	// Keep hub traffic on the physical path, then override the default route
	// with the two /1 halves through the tunnel interface.
	gwOut, err := exec.Command("powershell", "-NoProfile", "-Command",
		"(Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop").Output()
	if err != nil {
		return fmt.Errorf("find default gateway: %w", err)
	}
	gw := strings.TrimSpace(string(gwOut))
	if gw == "" {
		return fmt.Errorf("no default gateway")
	}
	if err := runCmd("route", "add", hubIP, "mask", "255.255.255.255", gw, "metric", "5"); err != nil {
		return err
	}
	if err := runCmd("route", "add", "0.0.0.0", "mask", "128.0.0.0", "0.0.0.0", "if", ifaceIndex(tunIface), "metric", "5"); err != nil {
		return err
	}
	return runCmd("route", "add", "128.0.0.0", "mask", "128.0.0.0", "0.0.0.0", "if", ifaceIndex(tunIface), "metric", "5")
}

func ifaceIndex(name string) string {
	out, err := exec.Command("powershell", "-NoProfile", "-Command",
		fmt.Sprintf("(Get-NetAdapter -Name '%s').ifIndex", name)).Output()
	if err != nil {
		return "0"
	}
	return strings.TrimSpace(string(out))
}

func osRemoveExitRoutes(tunIface, hubEndpoint string) {
	_ = runCmd("route", "delete", "0.0.0.0", "mask", "128.0.0.0")
	_ = runCmd("route", "delete", "128.0.0.0", "mask", "128.0.0.0")
	if hubIP, err := resolveHostIP(hubEndpoint); err == nil {
		_ = runCmd("route", "delete", hubIP)
	}
}

// Exit NAT on Windows uses WinNAT. Creating a NAT object needs an elevated
// one-time setup; we attempt it and report honestly if it is unavailable.
func osEnableExitNAT() error {
	script := `if (-not (Get-NetNat -Name YousjMeshNat -ErrorAction SilentlyContinue)) { New-NetNat -Name YousjMeshNat -InternalIPInterfaceAddressPrefix 10.99.0.0/24 | Out-Null }; Set-NetIPInterface -InterfaceAlias 'YousjMesh' -Forwarding Enabled`
	out, err := exec.Command("powershell", "-NoProfile", "-Command", script).CombinedOutput()
	if err != nil {
		return fmt.Errorf("WinNAT setup failed (run elevated once): %v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func osDisableExitNAT() {
	_ = runCmd("powershell", "-NoProfile", "-Command",
		"Remove-NetNat -Name YousjMeshNat -Confirm:$false -ErrorAction SilentlyContinue")
}
