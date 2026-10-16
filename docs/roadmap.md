# Implementation roadmap

The target is an understandable Linux runtime with roughly the features of kontainer-runtime, built in small working iterations. runc is the behavioral authority when implementations differ. Each phase needs Linux integration evidence; portable unit tests and successful compilation alone cannot establish namespace or container behavior.

## Progress

| Phase | Status |
| --- | --- |
| 1. Namespace lab | Implemented as `namespace-run`; Linux integration in `scripts/integration.sh`. |
| 2. OCI foreground run | Implemented as `run --bundle PATH ID` for a narrow subset; everything outside it is rejected (see README). Linux integration with a static BusyBox rootfs and runc comparison in `scripts/oci-integration.sh`. |
| 3. Persistent OCI lifecycle | Implemented for the phase 2 subset: `create`, `start`, `state`, `kill`, `delete`, `list`, and foreground/detached `run` with a `--root` state directory (see README). Linux integration with runc comparison in `scripts/lifecycle-integration.sh`. macOS unit tests and Linux debug/release unit and integration gates pass; the gaps listed below remain. |
| 4–6 | Not started. |

## 1. Namespace lab

First command:

```sh
swift-container-runtime namespace-run --hostname swiftbox -- /bin/sh -c 'hostname; echo $$'
```

Create UTS, PID, and mount namespaces; make propagation private; mount procfs for the new PID namespace; execute an absolute command path and report its exit status. Keep setup in synchronous Swift using conditional Glibc/Musl imports and minimal header-only Linux API adapters. Reject multithreaded callers before fork. No OCI bundle or isolated root filesystem yet.

Check hostname, PID 1 visibility, procfs namespace identity, surrounding hostname remaining unchanged, nonzero exit propagation, and actionable errors when namespace privileges are absent. Exercise this in Linux through the available Apple `container` installation where its guest permissions permit it.

## 2. OCI foreground run

Add typed bundle decoding and a validated immutable setup plan, supplied rootfs, private mount propagation, pivot_root, basic mounts and devices, cwd, environment, hostname, and nonterminal foreground execution. Reject requested features that are not implemented instead of silently discarding them.

Check a BusyBox bundle through both runc and this runtime: PID 1, root filesystem contents, hostname, cwd/environment, stdout/stderr, workload exit status, missing executable, and setup failure cleanup. Do not infer a security boundary from namespace creation alone.

References: kontainer `spec/Spec.kt`, `process/InitProcess.kt`, and `rootfs/Rootfs.kt`; runc `libcontainer/standard_init_linux.go` and `libcontainer/rootfs_linux.go`.

Implemented subset: new mount (required), pid, uts, ipc, and network namespaces. Mounts are `proc` at `/proc`, `tmpfs`, and `devpts` at `/dev/pts`, with nosuid/nodev/noexec/strictatime and validated data options. runc's default character devices and `/dev` links are created in a `/dev` tmpfs. The process takes an absolute `args[0]`, an explicit `env`, a created `cwd`, and uid/gid 0 only. Mount destinations are resolved per component from a rootfs descriptor with `O_NOFOLLOW`, and symlink components are rejected rather than resolved in-root as runc does. Setup then calls `pivot_root(".", ".")` and detaches the old root. Deliberate differences from runc: no PATH lookup, no `HOME` default, symlinked mount destinations fail, and `/dev` is populated only when it is a tmpfs. Every unknown or unimplemented `config.json` field is rejected. Phase 3 uses the validated ID as the state directory name. The bundle and rootfs are trusted and must stay unchanged during setup; launch pins the rootfs with `O_NOFOLLOW` and checks its identity after the self-bind, which detects but does not prevent host-side races.

## 3. Persistent OCI lifecycle

Implement `create`, `start`, `state`, `kill`, `delete`, detached `run`, and `list`. Store absolute bundle paths, validate container IDs, write state atomically, coordinate competing mutating commands across processes, and keep cleanup metadata independent of the source bundle. Track process identity with PID and `/proc/<pid>/stat` start time, with pidfds where useful.

Check that create leaves the workload waiting, start runs it exactly once, state reflects real exit, signals reach the intended process, invalid transitions fail, stopped containers delete, force deletion cleans up, duplicate IDs fail, PID reuse cannot target an unrelated process, and failed create/run clean up their processes and state. A failed start retains stopped state until deletion.

References: kontainer `command/{Create,Start,Run,State,Kill,Delete,List}.kt`, `state/State.kt`, and `channel/NotifySocket.kt`; runc `create.go`, `start.go`, `state.go`, `kill.go`, and `delete.go`.

Implemented design: no monitor process, as in runc. The launcher reports the init PID while it is an unreaped child; the CLI pins it with a pidfd and records PID, start time, and boot ID before releasing the launcher. A created init finishes setup, waits for a commit byte that follows the `state.json` write (EOF makes it exit), then serves `start.sock`. The init accepts only a connected client's request, unlinks the socket (the created-to-running marker), and execs; the close-on-exec connection gives `start` EOF on success or the exec error. Status is derived on each query (record, verified init, socket). Signals use `pidfd_send_signal` after verifying start time, boot ID, and PID namespace. Mutating commands hold a bounded per-container `flock`; `mkdirat` rejects duplicate IDs; `state.json` is replaced by fsync and rename. Foreground `run` keeps its parent-death signal chain and removes state on exit; a detached init has no parent-death signal and starts a new session.

Deliberate differences from runc: `start` reports exec failures; a dead `start` client before the request check does not consume the start; the state root must be private to its owner. Missing compared with runc and kontainer: `pause`/`resume`, hooks (including poststart/poststop), `NOTIFY_SOCKET`, `--pid-file`, `--console-socket`, `--pidfd-socket`, `--preserve-fds`, `run --keep`, `--no-subreaper`, signal forwarding for foreground `run` (phase 5), and cgroup-based killing of containers without a PID namespace (phase 4). Rootless state roots (`$XDG_RUNTIME_DIR`) are not handled.

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

Use Swift 6.4 (6.4.1 for Linux validation), swift-argument-parser for the CLI, swift-system for file descriptors and errors, and a minimal header-only Linux API target. Enable strict memory-safety diagnostics and warnings-as-errors in all project-owned Swift targets. Prefer safe initialization and borrowed memory APIs such as OutputSpan and Span; keep unavoidable raw-pointer operations scoped and documented. SystemPackage is the descriptor/error foundation; wrap copyable descriptor values in explicit noncopyable owners, and use FilePath when bundle and state-directory paths are introduced. Discuss other package dependencies before introducing them. Conditionally import Musl or Glibc; keep only missing declarations and fixed-signature variadic adapters in the Linux header. Launch runs synchronously before background work begins; future async supervision must preserve that boundary or introduce a fresh bootstrap process. Linux-specific kernel calls are expected. Portability to musl is an implementation goal requiring a real build and execution test, not a current compatibility claim.

All kontainer Kotlin paths above are relative to `src/nativeMain/kotlin/` in [ternbusty/kontainer-runtime](https://github.com/ternbusty/kontainer-runtime), except paths explicitly starting with `scripts/`, `test-scripts/`, or `src/nativeInterop/`. runc paths are relative to [opencontainers/runc](https://github.com/opencontainers/runc). The namespace and lifecycle behavior should be checked against those sources and Linux itself as each phase is implemented.
