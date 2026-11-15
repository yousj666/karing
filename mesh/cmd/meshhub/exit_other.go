//go:build !linux

package main

import (
	"crypto/tls"
	"fmt"
	"net/http"
	"os/exec"
	"runtime"
	"strings"
)

func insecureTransport() http.RoundTripper {
	return &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}} //nolint:gosec
}

func assignAddr(iface, cidr string) error {
	if isWindows() {
		out, err := exec.Command("netsh", "interface", "ipv4", "set", "address",
			"name="+iface, "static", strings.Split(cidr, "/")[0], "255.255.255.0").CombinedOutput()
		if err != nil {
			return fmt.Errorf("netsh: %v: %s", err, strings.TrimSpace(string(out)))
		}
		return nil
	}
	return fmt.Errorf("assignAddr not implemented on this platform")
}

func isWindows() bool { return runtime.GOOS == "windows" }

// Exit policy routing is implemented for the Linux hub (the deployment
// target). On other platforms it is a deliberate no-op with a log line.
func reconcileExitRules(peers []hubPeer) {}

func ensureForwardRule(iface string) {}
