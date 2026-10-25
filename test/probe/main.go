// Command probe checks whether syscalls are blocked by the image's built-in
// sandbox-exec filter or by seccomp/tailscale.json.
//
// PROBE_MODE=ssh (default) checks the four syscalls Tailscale SSH needs:
// setgroups, setgid, setuid and ptrace. PROBE_MODE=profile checks setresuid
// and ptrace, which the shipped profile removes but runc does not need.
package main

import (
	"fmt"
	"os"
	"syscall"
)

func main() {
	mode := os.Getenv("PROBE_MODE")
	if mode == "" {
		mode = "ssh"
	}

	type check struct {
		name string
		err  error
	}
	var checks []check

	ptraceErr := func() error {
		_, _, errno := syscall.Syscall(syscall.SYS_PTRACE, 0, 0, 0)
		if errno == 0 {
			return nil
		}
		return errno
	}

	switch mode {
	case "ssh":
		checks = []check{
			{name: "setgroups", err: syscall.Setgroups([]int{})},
			{name: "setgid", err: syscall.Setgid(0)},
			{name: "setuid", err: syscall.Setuid(0)},
			{name: "ptrace", err: ptraceErr()},
		}
	case "profile":
		checks = []check{
			{name: "setresuid", err: syscall.Setresuid(0, 0, 0)},
			{name: "ptrace", err: ptraceErr()},
		}
	default:
		fmt.Fprintf(os.Stderr, "unknown PROBE_MODE %q\n", mode)
		os.Exit(2)
	}

	failed := false
	for _, c := range checks {
		if c.err == nil {
			fmt.Printf("%s: allowed\n", c.name)
			failed = true
		} else {
			fmt.Printf("%s: %v\n", c.name, c.err)
		}
	}
	if failed {
		fmt.Println("some syscalls were not blocked")
		os.Exit(1)
	}
	fmt.Println("all expected syscalls are blocked")
}
