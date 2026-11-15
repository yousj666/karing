//go:build darwin

package main

import "fmt"

// macOS is not a phase-1 target; the control plane works, tunnel OS glue is
// left as explicit stubs rather than silent no-ops.
func tunName() string { return "utun" }

func osAssignIP(iface, vip string) error {
	return fmt.Errorf("macOS tunnel support not in phase 1 scope")
}
func osAddExitRoutes(tunIface, hubEndpoint string) error {
	return fmt.Errorf("macOS exit routing not in phase 1 scope")
}
func osRemoveExitRoutes(tunIface, hubEndpoint string) {}
func osEnableExitNAT() error {
	return fmt.Errorf("macOS exit NAT not in phase 1 scope")
}
func osDisableExitNAT() {}
