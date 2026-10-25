// Command sandbox-exec installs a small seccomp filter and then execs the
// container's real entrypoint (containerboot).
//
// The filter exists for one reason: Tailscale SSH drops privileges in
// `tailscaled be-child` by calling setgroups/setgid/setuid. Blocking those
// syscalls makes every Tailscale SSH session fail, including sessions for
// root, while leaving the rest of tailscaled alone. ptrace and the
// process_vm/kcmp/pidfd_getfd family are blocked as well so that the
// unprivileged part of the daemon cannot inspect or inject into other
// processes.
//
// The filter is a denylist layered on top of the runtime's default seccomp
// profile. It is intentionally tiny; seccomp/tailscale.json contains the full
// allowlist profile for deployments that want more.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"syscall"
	"unsafe"

	"golang.org/x/sys/unix"
)

const (
	auditArchX86_64  = 0xc000003e
	auditArchAArch64 = 0xc00000b7
	auditArchARM     = 0x40000028

	// Syscall numbers on amd64 have this bit set for the x32 ABI. The x32
	// numbers are different, so reject the whole range rather than matching
	// each blocked syscall twice.
	x32SyscallBit = 0x40000000
)

// blockedSyscalls are the syscalls disabled for the whole container.
//
// setgroups is the important one: ssh/tailssh/incubator.go calls it
// unconditionally in doDropPrivileges, before setgid/setuid and even when the
// target user is root. Without it no Tailscale SSH session can start.
var blockedSyscalls = []int{
	unix.SYS_SETUID,
	unix.SYS_SETGID,
	unix.SYS_SETREUID,
	unix.SYS_SETREGID,
	unix.SYS_SETRESUID,
	unix.SYS_SETRESGID,
	unix.SYS_SETFSUID,
	unix.SYS_SETFSGID,
	unix.SYS_SETGROUPS,

	unix.SYS_PTRACE,
	unix.SYS_PROCESS_VM_READV,
	unix.SYS_PROCESS_VM_WRITEV,
	unix.SYS_KCMP,
	unix.SYS_PIDFD_GETFD,
	unix.SYS_PROCESS_MADVISE,
}

func main() {
	// Seccomp filters and no_new_privs are per-thread. Keep this goroutine on
	// the same OS thread until execve so the new program inherits both.
	runtime.LockOSThread()

	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: sandbox-exec PROGRAM [ARGS...]")
		os.Exit(2)
	}

	if err := installFilter(); err != nil {
		fmt.Fprintf(os.Stderr, "sandbox-exec: installing seccomp filter: %v\n", err)
		os.Exit(1)
	}

	argv := os.Args[1:]
	path, err := exec.LookPath(argv[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "sandbox-exec: %v\n", err)
		os.Exit(1)
	}
	if err := unix.Exec(path, argv, os.Environ()); err != nil {
		fmt.Fprintf(os.Stderr, "sandbox-exec: exec %s: %v\n", path, err)
		os.Exit(1)
	}
}

func installFilter() error {
	arch, err := auditArch()
	if err != nil {
		return err
	}

	errnoRet := uint32(unix.SECCOMP_RET_ERRNO) | uint32(syscall.EPERM)

	filter := []unix.SockFilter{
		// acc = seccomp_data.arch
		bpfStmt(unix.BPF_LD|unix.BPF_W|unix.BPF_ABS, 4),
		// if (arch != expected) kill;
		bpfJump(unix.BPF_JMP|unix.BPF_JEQ|unix.BPF_K, 1, 0, arch),
		bpfStmt(unix.BPF_RET|unix.BPF_K, unix.SECCOMP_RET_KILL_PROCESS),

		// nr = seccomp_data.nr
		bpfStmt(unix.BPF_LD|unix.BPF_W|unix.BPF_ABS, 0),

		// if (nr >= x32SyscallBit) errno(EPERM);
		bpfJump(unix.BPF_JMP|unix.BPF_JGE|unix.BPF_K, 0, 1, x32SyscallBit),
		bpfStmt(unix.BPF_RET|unix.BPF_K, errnoRet),
	}

	for _, nr := range blockedSyscalls {
		// if (nr == blocked) errno(EPERM); else continue
		filter = append(filter,
			bpfJump(unix.BPF_JMP|unix.BPF_JEQ|unix.BPF_K, 0, 1, uint32(nr)),
			bpfStmt(unix.BPF_RET|unix.BPF_K, errnoRet),
		)
	}
	filter = append(filter, bpfStmt(unix.BPF_RET|unix.BPF_K, unix.SECCOMP_RET_ALLOW))

	prog := unix.SockFprog{
		Len:    uint16(len(filter)),
		Filter: &filter[0],
	}

	// seccomp filters cannot be installed without no_new_privs unless the
	// caller has CAP_SYS_ADMIN. Setting it is harmless for tailscaled: there
	// are no setuid binaries in this image and existing capabilities are
	// retained.
	if err := unix.Prctl(unix.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0); err != nil {
		return fmt.Errorf("prctl(PR_SET_NO_NEW_PRIVS): %w", err)
	}

	if _, _, errno := unix.Syscall(
		unix.SYS_SECCOMP,
		unix.SECCOMP_SET_MODE_FILTER,
		0,
		uintptr(unsafe.Pointer(&prog)),
	); errno != 0 {
		return fmt.Errorf("seccomp(SECCOMP_SET_MODE_FILTER): %w", errno)
	}
	runtime.KeepAlive(filter)
	return nil
}

func auditArch() (uint32, error) {
	switch runtime.GOARCH {
	case "amd64":
		return auditArchX86_64, nil
	case "arm64":
		return auditArchAArch64, nil
	case "arm":
		return auditArchARM, nil
	default:
		return 0, fmt.Errorf("unsupported architecture %q", runtime.GOARCH)
	}
}

func bpfStmt(code uint16, k uint32) unix.SockFilter {
	return unix.SockFilter{Code: code, K: k}
}

func bpfJump(code uint16, jt, jf uint8, k uint32) unix.SockFilter {
	return unix.SockFilter{Code: code, Jt: jt, Jf: jf, K: k}
}
