# Implementation roadmap

The target is an understandable Linux runtime with roughly the features of kontainer-runtime, built in small working iterations. runc is the behavioral authority when implementations differ. Each phase needs Linux integration evidence; portable unit tests and successful compilation alone cannot establish namespace or container behavior.

## Progress

| Phase | Status |
| --- | --- |
| 1. Namespace lab | Implemented as `namespace-run`; Linux integration in `scripts/integration.sh`. |
| 2. OCI foreground run | Implemented as `run --bundle PATH ID` for a narrow subset; everything outside it is rejected (see README). Linux integration with a static BusyBox rootfs and runc comparison in `scripts/oci-integration.sh`. |
| 3. Persistent OCI lifecycle | Implemented for the phase 2 subset: `create`, `start`, `state`, `kill`, `delete`, `list`, and foreground/detached `run` with a `--root` state directory (see README). Linux integration with runc comparison in `scripts/lifecycle-integration.sh`. macOS unit tests and Linux debug/release unit and integration gates pass; the gaps listed below remain. |
| 4. Security and resource setup | In progress. Process credentials implemented: `process.user` uid/gid/additionalGids/umask and `noNewPrivileges`, for foreground `run`, detached `run`, and `create`/`start`, with the start gate moved to a host-side marker commit. Linux integration with runc comparison in `scripts/credentials-integration.sh`. Capabilities implemented: all five `process.capabilities` sets in runc's order around the credential switch, with `scripts/capabilities-integration.sh`. Rlimits implemented: all sixteen `process.rlimits` names, every entry applied exactly and in order at runc's procReady point (before capabilities and credentials change, and before create reports readiness), with `scripts/rlimits-integration.sh`. Readonly rootfs implemented: `root.readonly` remounts the container's root mount read-only after mounts, `/dev`, and cwd creation, before rlimits, capabilities, credentials, and readiness, keeping its `nosuid`/`nodev`/`noexec` flags and leaving child mounts writable, with `scripts/readonly-integration.sh`. `linux.readonlyPaths` and `linux.maskedPaths` implemented after the read-only root and before privilege changes, resolved in the container root without magic links and mounted through descriptors without `/proc`, with a verified `/dev/null`, a shared read-only directory mask, and visibility checks, in `scripts/path-controls-integration.sh`. A cgroup v2 memory/pids/CPU subset is implemented (see below), with `scripts/cgroup-integration.sh`, `scripts/cpu-integration.sh`, and `scripts/cpuset-integration.sh`; this is not full resource parity. CPU realtime, the other resources, seccomp, and hooks remain; update covers the supported resource subset. |
| 5. Exec, rootless, terminal | Basic nonterminal exec command and standalone process JSON implemented (see README), sharing process setup with init. Rootless and terminals remain. |
| 6. Broader parity | Pause/resume, ps, events, spec generation, features, and version reporting implemented; remaining inventory below. |

The phase 4 cgroup v2 subset covers:

- `linux.cgroupsPath`.
- `linux.resources.memory` `limit`, `reservation` and `swap`, `pids.limit`, and `cpu` `shares`, `quota`, `period`, `burst`, `idle`, `cpus` and `mems`, with runc's conversions, write order, and burst retry.
- Controller enablement.
- Membership before readiness, under a cross-process `flock` on the leaf, so concurrent containers given one path cannot both adopt it.
- Cgroup identity in the state, with boot ID and inode.
- Cleanup and `cgroup.kill` on foreground exit, failed setup, `delete` and `delete --force`.

Linux integration with runc comparison is in `scripts/cgroup-integration.sh`, `scripts/cpu-integration.sh`, and `scripts/cpuset-integration.sh`; CPU quota enforcement is proved through `cpu.stat` throttling, while weight values are checked by readback; fairness is not measured. This is not full resource parity: CPU realtime and the other resources are rejected. Update covers the supported subset with saved merge semantics and memory usage checks.

Current priority: finish useful basic command functionality before extending advanced OCI behavior. Preserve the unfinished hooks draft for later; basic exec precedes it.

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

Implemented subset: new mount (required), pid, uts, ipc, and network namespaces. Mounts are `proc` at `/proc`, `tmpfs`, and `devpts` at `/dev/pts`, with nosuid/nodev/noexec/strictatime and validated data options. runc's default character devices and `/dev` links are created in a `/dev` tmpfs. The process takes an absolute `args[0]`, an explicit `env`, a created `cwd`, with configured uid/gid and supplementary groups (added in phase 4). Mount destinations are resolved per component from a rootfs descriptor with `O_NOFOLLOW`, and symlink components are rejected rather than resolved in-root as runc does. Setup then calls `pivot_root(".", ".")` and detaches the old root. Deliberate differences from runc: no PATH lookup, no `HOME` default, symlinked mount destinations fail, and `/dev` is populated only when it is a tmpfs. Every unknown or unimplemented `config.json` field is rejected. Phase 3 uses the validated ID as the state directory name. The bundle and rootfs are trusted and must stay unchanged during setup; launch pins the rootfs with `O_NOFOLLOW` and checks its identity after the self-bind, which detects but does not prevent host-side races.

## 3. Persistent OCI lifecycle

Implement `create`, `start`, `state`, `kill`, `delete`, detached `run`, and `list`. Store absolute bundle paths, validate container IDs, write state atomically, coordinate competing mutating commands across processes, and keep cleanup metadata independent of the source bundle. Track process identity with PID and `/proc/<pid>/stat` start time, with pidfds where useful.

Check that create leaves the workload waiting, start runs it exactly once, state reflects real exit, signals reach the intended process, invalid transitions fail, stopped containers delete, force deletion cleans up, duplicate IDs fail, PID reuse cannot target an unrelated process, and failed create/run clean up their processes and state. A failed start retains stopped state until deletion.

References: kontainer `command/{Create,Start,Run,State,Kill,Delete,List}.kt`, `state/State.kt`, and `channel/NotifySocket.kt`; runc `create.go`, `start.go`, `state.go`, `kill.go`, and `delete.go`.

Implemented design: no monitor process, as in runc. The launcher reports the init PID while it is an unreaped child; the CLI pins it with a pidfd and records PID, start time, and boot ID before releasing the launcher, which stays the init's parent until the verdict: on success it exits and leaves the detached process to the caller's subreaper, as runc does; on a failure within the launch handshake (including exec's PID-file publication) it reaps the child the CLI killed. Follow-up: `create`/`run --detach` PID-file publication happens after the launcher exits, so its failure cleanup does not yet reap the init. A created init finishes setup, waits for a commit byte that follows the `state.json` write (EOF makes it exit), then serves `start.sock`. The init accepts a connected client's request; the locked host `start` command unlinks the socket (the created-to-running marker) and sends the commit before init execs; the close-on-exec connection gives `start` EOF on success or the exec error. Status is derived on each query (record, verified init, socket). Signals use `pidfd_send_signal` after verifying start time, boot ID, and PID namespace. Mutating commands hold a bounded per-container `flock`; `mkdirat` rejects duplicate IDs; `state.json` is replaced by fsync and rename. Foreground `run` keeps its parent-death signal chain and removes state on exit; a detached init has no parent-death signal and starts a new session.

Deliberate differences from runc: `start` reports exec failures; a dead `start` client before the request check does not consume the start; the state root must be private to its owner. Missing compared with runc and kontainer: hooks (including poststart/poststop), `NOTIFY_SOCKET`, `--console-socket`, `--pidfd-socket`, `--preserve-fds`, `--no-subreaper`, signal forwarding for foreground `run` (phase 5), and `kill` reaching processes other than the init in containers without a PID namespace. `delete` does kill those processes, through `cgroup.kill`. Rootless state roots (`$XDG_RUNTIME_DIR`) are not handled. `run --keep` retains stopped state and its cgroup for explicit deletion. `create` and `run` atomically publish host init PIDs with `--pid-file`; publication failures clean up the launch.

`pause`/`resume` use the cgroup v2 freezer, including paused state/list output, freezing a created init, confirmed completion, and killing/deleting while frozen. `scripts/freezer-integration.sh` checks actual suspension and resumed progress against runc, with boot/inode protection and bystander isolation.

## 4. Security and resource setup

Add UID/GID and supplementary groups, capability sets, no_new_privs, rlimits, umask, masked and readonly paths, readonly rootfs, and cgroup v2 memory/CPU/pids limits. Apply controls before allowing the workload to execute. Add seccomp filtering with its dependency or implementation choice discussed before adoption.

Check actual identities and capability masks, denied operations, readonly/masked paths, limit files and enforcement, cgroup cleanup, invalid settings, and setup ordering. Add lifecycle hooks and their timeout, environment, state-input, and failure semantics.

Implemented increment (credentials): after the cwd and before the executable lookup, the init follows runc's order: umask (default 0022, not inherited), `PR_SET_NO_NEW_PRIVS` when requested, chown of inherited stdio to the uid (runc's fixStdioPermissions), `setgroups` (always, so an empty or absent list clears the caller's groups), `setgid`, `setuid`. The foreground init then rearms its parent-death signal, which the credential change cleared, and rechecks the launcher pidfd, as runc restores pdeath after finalizeNamespace. The executable lookup runs with the workload credentials, so a root-only program fails `create`. Because a created init no longer runs as root, it cannot unlink the marker in the private state directory: `start` (root, holding the lock) unlinks `start.sock` after the init accepts the request, then sends a commit; the init decides from the marker inode's link count, read through an inherited O_PATH handle, whether to exec, keep serving, or exit. Without `PR_SET_KEEPCAPS`, a non-root uid loses its permitted set at `setuid` rather than at `execve` as in runc; the workload sees the same empty sets. User namespaces (so rootless mappings and `/proc/self/setgroups` handling) are still missing.

Implemented increment (capabilities): `process.capabilities` follows runc's finalizeNamespace. An absent object changes nothing (runc's `capabilities.New(nil)` is a no-op), so the credentials behavior above still holds. A present object is authoritative and absent members are empty. After `no_new_privs`, every capability in `0...cap_last_cap` outside `bounding` and still in the bounding set is dropped while the init holds `CAP_SETPCAP`; `PR_SET_KEEPCAPS` is set; the user switch and cwd retry run; keepcaps is cleared; `capset` (version 3) installs effective, permitted, and inheritable; the ambient set is cleared and each configured ambient capability raised. Then the foreground parent-death signal is rearmed as before. Deliberate differences from runc, which warns and continues: unknown names, names above `cap_last_cap`, ambient ⊄ permitted ∩ inheritable, and failed ambient raises are errors. Effective ⊄ permitted is rejected before launch rather than at `capset`. Inheritable is not checked against bounding: `capset` keeps bits the init already inherited, which the integration script shows with a caller's inheritable `CAP_NET_RAW` kept outside a reduced bounding set; a bit neither bounded nor inherited fails at `capset` under both runtimes. runc's second bounding pass in ApplyCaps (skipped without `CAP_SETPCAP` in effective) is omitted, since the bounding set cannot grow. The kernel decides permitted ⊆ the runtime's own permitted set at `capset`, reported as a setup error. Names are fixed through `CAP_CHECKPOINT_RESTORE` (40); newer kernel capabilities can be dropped but not requested. Securebits are not configured.

References: kontainer `process/ProcessSecurity.kt`, `capability/Capability.kt`, `cgroup/CgroupV2.kt`, `seccomp/Seccomp.kt`, and `hook/Hook.kt`; runc `libcontainer/standard_init_linux.go`, `libcontainer/seccomp`, and `vendor/github.com/opencontainers/cgroups`.

## 5. Exec, rootless operation, and terminal support

Implement joining existing namespaces, `exec` with cwd/env/user and exit-status handling, user namespace mapping handshake, rootless create/run, PTY console handoff and foreground I/O, signal forwarding, and terminal resizing. Revisit process creation only with measured runtime thread behavior and kernel constraints in hand.

Check exec sees the existing rootfs/namespaces and requested credentials; failed joins cannot affect the caller; rootless UID/GID mappings match the bundle; terminal ownership and dimensions are correct; cancellation and signals do not leak processes or descriptors.

References: kontainer `command/Exec.kt`, `console/Console.kt`, `command/Foreground.kt`, `process/MainProcess.kt`, and `src/nativeInterop/cinterop/bootstrap/bootstrap.c`; runc `libcontainer/nsenter/nsexec.c`, `libcontainer/setns_init_linux.go`, and `libcontainer/process_linux.go`.

## 6. Broader kontainer-runtime parity

The remaining inventory is deliberately explicit so that a working minimal runtime is not mistaken for feature parity:

| Area | Features to add and verify |
| --- | --- |
| Lifecycle and observability | updates for unimplemented resources, pidfd socket |
| Mounts | bind/rbind option semantics, propagation, recursive attributes, idmapped mounts, safe path resolution, no-pivot mode |
| Namespaces | joining supplied namespace paths, cgroup and time namespaces, time offsets, shared/host namespace combinations |
| Resources | CPU realtime runtime/period, the remaining memory fields, unified cgroup v2 controls, hugepages, block I/O, network/RDMA, device BPF rules, updates for those controls, cleanup of created ancestor cgroups (memory limit/reservation/swap, pids limit, and CPU shares/quota/period/burst/idle and cpusets are implemented) |
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
