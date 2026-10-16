# Implementation roadmap

The target is an understandable Linux runtime with roughly the features of kontainer-runtime, built in small working iterations. runc is the behavioral authority when implementations differ. Each phase needs Linux integration evidence; portable unit tests and successful compilation alone cannot establish namespace or container behavior.

## 1. Namespace lab

First command:

```sh
swift-container-runtime namespace-run --hostname swiftbox -- /bin/sh -c 'hostname; echo $$'
```

Create UTS, PID, and mount namespaces; make propagation private; mount procfs for the new PID namespace; execute an absolute command path and report its exit status. Keep post-fork setup in a small C shim. No OCI bundle or isolated root filesystem yet.

Check hostname, PID 1 visibility, procfs namespace identity, surrounding hostname remaining unchanged, nonzero exit propagation, and actionable errors when namespace privileges are absent. Exercise this in Linux through the available Apple `container` installation where its guest permissions permit it.

## 2. OCI foreground run

Add typed bundle decoding and a validated immutable setup plan, supplied rootfs, private mount propagation, pivot_root, basic mounts and devices, cwd, environment, hostname, and nonterminal foreground execution. Reject requested features that are not implemented instead of silently discarding them.

Check a BusyBox bundle through both runc and this runtime: PID 1, root filesystem contents, hostname, cwd/environment, stdout/stderr, workload exit status, missing executable, and setup failure cleanup. Do not infer a security boundary from namespace creation alone.

References: kontainer `spec/Spec.kt`, `process/InitProcess.kt`, and `rootfs/Rootfs.kt`; runc `libcontainer/standard_init_linux.go` and `libcontainer/rootfs_linux.go`.

## 3. Persistent OCI lifecycle

Implement `create`, `start`, `state`, `kill`, `delete`, detached `run`, and `list`. Store absolute bundle paths, validate container IDs, write state atomically, coordinate competing mutating commands across processes, and keep cleanup metadata independent of the source bundle. Track process identity with PID and `/proc/<pid>/stat` start time, with pidfds where useful.

Check that create leaves the workload waiting, start runs it exactly once, state reflects real exit, signals reach the intended process, invalid transitions fail, stopped containers delete, force deletion cleans up, duplicate IDs fail, PID reuse cannot target an unrelated process, and failure leaves no orphan process or state directory.

References: kontainer `command/{Create,Start,Run,State,Kill,Delete,List}.kt`, `state/State.kt`, and `channel/NotifySocket.kt`; runc `create.go`, `start.go`, `state.go`, `kill.go`, and `delete.go`.

## 4. Security and resource setup

Add UID/GID and supplementary groups, capability sets, no_new_privs, rlimits, umask, masked and readonly paths, readonly rootfs, and cgroup v2 memory/CPU/pids limits. Apply controls before allowing the workload to execute. Add seccomp filtering with its dependency or implementation choice discussed before adoption.

Check actual identities and capability masks, denied operations, readonly/masked paths, limit files and enforcement, cgroup cleanup, invalid settings, and setup ordering. Add lifecycle hooks and their timeout, environment, state-input, and failure semantics.

References: kontainer `process/ProcessSecurity.kt`, `capability/Capability.kt`, `cgroup/CgroupV2.kt`, `seccomp/Seccomp.kt`, and `hook/Hook.kt`; runc `libcontainer/standard_init_linux.go`, `libcontainer/seccomp`, and `vendor/github.com/opencontainers/cgroups`.

## 5. Exec, rootless operation, and terminal support

Implement joining existing namespaces, `exec` with cwd/env/user and exit-status handling, user namespace mapping handshake, rootless create/run, PTY console handoff and foreground I/O, signal forwarding, and terminal resizing. Revisit process creation only with measured runtime thread behavior and kernel constraints in hand.

Check exec sees the existing rootfs/namespaces and requested credentials; failed joins cannot affect the caller; rootless UID/GID mappings match the bundle; terminal ownership and dimensions are correct; cancellation and signals do not leak processes or descriptors.

References: kontainer `command/Exec.kt`, `console/Console.kt`, `command/Foreground.kt`, `process/MainProcess.kt`, and `src/nativeInterop/cinterop/bootstrap/bootstrap.c`; runc `libcontainer/nsenter/nsexec.c`, `libcontainer/setns_init_linux.go`, and `libcontainer/process_linux.go`.

## 6. Broader kontainer-runtime parity

The remaining inventory is deliberately explicit so that a working minimal runtime is not mistaken for feature parity:

| Area | Features to add and verify |
| --- | --- |
| Lifecycle and observability | pause/resume, ps, events/stats/OOM, resource update, pid-file/pidfd socket, retained state |
| Mounts | bind/rbind option semantics, propagation, recursive attributes, idmapped mounts, safe path resolution, no-pivot mode |
| Namespaces | joining supplied namespace paths, cgroup and time namespaces, time offsets, shared/host namespace combinations |
| Resources | cpusets, unified cgroup v2 controls, hugepages, block I/O, device BPF rules, recursive cleanup |
| Security | seccomp argument rules and notification FD handoff, AppArmor/SELinux labels, session keyring, sealed executable handoff |
| Process setup | HOME resolution, preserved descriptors/socket activation, scheduling, I/O priority, CPU affinity, NUMA memory policy |
| Networking | loopback setup and moving/configuring interfaces in a target namespace |
| Integration | selected runc bats compatibility tests, rootless cases, containerd compatibility |
| Portability | arm64 and x86_64 Linux; explicit musl/static build verification |

References: kontainer `scripts/runc_test_pattern` inventories selected upstream compatibility cases; `scripts/runc-compat-test.sh` drives runc bats tests. Its inclusion of a test name is not proof that a particular checkout passes it. kontainer `test-scripts/verify-from-container.sh` is useful for exploration; Swift tests should assert expected results rather than only print observations.

Checkpoint/restore, cgroup v1, and systemd cgroup management are outside the initial parity target. Their omission should remain visible in documentation and feature reporting.

## Dependency and portability policy

Start with Swift standard libraries and a small C target. SystemPackage remains an option if it simplifies ownership or syscall wrappers. Discuss other package dependencies before introducing them. Isolate libc-facing details behind the C shim rather than importing GNU libc into Swift; Linux-specific kernel calls are expected. Portability to musl is an implementation goal requiring a real build and execution test, not a current compatibility claim.

All kontainer Kotlin paths above are relative to `src/nativeMain/kotlin/` in [ternbusty/kontainer-runtime](https://github.com/ternbusty/kontainer-runtime), except paths explicitly starting with `scripts/`, `test-scripts/`, or `src/nativeInterop/`. runc paths are relative to [opencontainers/runc](https://github.com/opencontainers/runc). The namespace and lifecycle behavior should be checked against those sources and Linux itself as each phase is implemented.
