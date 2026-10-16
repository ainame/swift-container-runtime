# kontainer-runtime parity checklist

The goal is feature parity with the behavior implemented by [kontainer-runtime at 357b8f2](https://github.com/ternbusty/kontainer-runtime/tree/357b8f295a7fad450c822c61e79cf22f75546640). runc is the behavioral authority when the implementations differ. This checklist records the target's actual code paths, rather than assuming that a decoded schema field or a compatibility-test name proves working behavior. The [roadmap](roadmap.md) orders the implementation; completing one phase does not complete this checklist.

## Commands

| Surface | Target behavior | Swift status |
| --- | --- | --- |
| `run` | Bundle, foreground wait/status/cleanup, detach, keep, PID file, console socket, pidfd socket, no-pivot | Foreground and detached subset implemented; keep and descriptor/console options missing |
| `create`, `start`, `state`, `kill`, `delete`, `list` | Persistent transitions and process identity; named/numeric signals; kill-all; force deletion; table/JSON/quiet listing | Core lifecycle implemented; kill-all without a private PID namespace and optional flags remain missing |
| `pause`, `resume` | Cgroup freezer | Missing |
| `update` | Resources file or stdin; individual resource flags; memory check-before-update | Missing |
| `events` | Stats snapshot or interval stream, OOM events, termination on deletion | Missing |
| `ps` | Table/JSON output and verbatim trailing host `ps` arguments | Missing |
| `exec` | Command or process JSON; detach, terminal, console/PID/pidfd; cwd, env, user/groups, capabilities, preserved FDs, sub-cgroup, ignore-paused | Missing |
| `spec` | Generate default `config.json`; bundle and rootless options | Missing |
| `features` | OCI feature JSON matching actual runtime support | Missing |
| Global options | State root, log path, text/JSON logs, debug | State root implemented; logging missing |
| Version | Runtime version, commit, OCI specification version; `--version`/`-v` | Missing |

Evidence: target `Main.kt`, `command/*.kt`, `state/State.kt`, and `config/KontainerConfig.kt`.

## OCI configuration and runtime behavior

| Area | Remaining target behavior |
| --- | --- |
| Process setup | PATH lookup; HOME resolution; empty/omitted-process behavior; UID/GID/additional groups/umask; rlimits; OOM score; scheduling, I/O priority, CPU affinity |
| Namespaces | Join supplied namespace paths; host/shared combinations; user, cgroup, time namespaces; UID/GID mapping handshake and mapping-helper fallback; time offsets |
| Rootfs and mounts | Readonly root; no-pivot; sysfs, mqueue, shm and cgroup mounts; bind/rbind/remount and propagation; recursive attributes; idmapped mounts; custom character/block/FIFO devices with ownership/mode; masked/readonly paths; sysctl |
| UTS and networking | Domainname; loopback setup; moving and renaming host interfaces. Hostname and new, unconfigured network namespaces already exist |
| Cgroup v2 | Path management and cleanup; memory limit/reservation/swap; CPU shares/quota/period/burst/idle; cpusets; pids; hugepages; unified controls; block-I/O weight/throttles; device BPF; update and check-before-update |
| Security | Five capability sets; no-new-privileges; AppArmor/SELinux execution-context staging and availability behavior; session keyrings; sealed executable handoff |
| Seccomp | Actions, architectures, argument comparisons, conditional rules, flags, notification listener handoff |
| Hooks | All six phases, environment, state on stdin, timeout and failure semantics |
| Foreground and descriptors | Signal forwarding, terminal I/O/resizing, console handoff, socket activation, explicit preserved descriptors. OCI foreground execution already marks inherited non-stdio descriptors close-on-exec |
| Portability and integration | arm64 and x86_64 Linux; real musl/static build and execution; applicable runc compatibility tests; containerd/go-runc interactions |

The current foreground and persistent lifecycle subset has real Linux debug/release evidence for PID 1, pivoted rootfs, proc/tmpfs/devpts, standard devices, hostname, cwd, explicit environment, stdio, status propagation, rejected configurations, descriptor cleanup, lifecycle transitions, concurrent create/start, signal delivery, stale process identity protection, and failure cleanup. It does not establish the remaining behavior above.

Evidence paths in the target, relative to `src/nativeMain/kotlin/`:

- Process: `spec/Spec.kt`, `process/InitProcess.kt`, `process/ProcessSecurity.kt`, `process/{HomeResolver,Scheduler,IOPriority,CpuAffinity}.kt`, `command/Exec.kt`.
- Namespaces: `command/Create.kt`, `process/MainProcess.kt`, and `src/nativeInterop/cinterop/bootstrap/bootstrap.c` (the last path is relative to the repository root).
- Mounts/network: `rootfs/Rootfs.kt`, `process/InitProcess.kt`, `process/MainProcess.kt`, and native network interop.
- Resources: `cgroup/{CgroupV2,DeviceCgroup}.kt`, `command/Update.kt`.
- Security/integration: `hook/Hook.kt`, `seccomp/*.kt`, `process/SessionKeyring.kt`, `exeseal/ExeSeal.kt`, `command/Foreground.kt`, `console/Console.kt`.

## What is not evidence of a parity requirement

The target mentions checkpoint/restore in help names but does not register or implement those commands. Its `--systemd-cgroup` option explicitly reports that it is unimplemented, and its resource implementation uses cgroup v2. Checkpoint/restore, cgroup v1, and systemd-managed cgroups are therefore outside this target's implemented functionality.

Likewise, `linux.mountLabel` and `blockIO.leafWeight` appear in its schema without applying consumers. AppArmor and SELinux have staging code while its feature report says they are disabled; parity needs platform-aware availability and error tests rather than an unconditional support claim.

A feature becomes complete only after its implementation and relevant observable behavior have been checked. Passing a narrow fixture or matching a CLI name is not full feature parity.
