# kontainer-runtime parity checklist

The feature baseline is the functionality implemented by [kontainer-runtime at 357b8f2](https://github.com/ternbusty/kontainer-runtime/tree/357b8f295a7fad450c822c61e79cf22f75546640). The goal is comparable functionality, not identical behavior on every runc edge case. Use runc to clarify OCI semantics and security ordering, and match the concrete contracts of supported consumers; Swift-native formatting, diagnostics and stricter validation can remain different. This checklist records the target's actual code paths, rather than assuming that a decoded schema field or a compatibility-test name proves working behavior. The [roadmap](roadmap.md) orders the implementation; completing one phase does not complete this checklist.

## Current scope and option comparison

Feature work resumes after the Swift refactor, following the [ordered roadmap](roadmap.md). The target remains kontainer-runtime's implemented functionality at the pinned commit, with [Docker through the existing containerd runc shim](docker-integration.md) as an additional usage goal. This inventory was reassessed against applying source code on 2026-10-18; it does not claim a fresh Linux integration pass. Existing runc comparisons remain valuable regression coverage, but matching every diagnostic, serialization detail or bootstrap limitation is not a completion criterion.

The table below separates the target's actual command options from Swift extensions. “Implemented” describes landed Swift code; the socket-activation draft is excluded from that status. Target support is established by local source inspection, not by running its complete option matrix.

| Option or behavior | kontainer-runtime at `357b8f2` | Landed Swift status | When it matters |
| --- | --- | --- | --- |
| `--detach`, `--pid-file` | `run` and `exec`; PID files also on `create` | Implemented | Launch in the background and let a caller track the workload. |
| `--keep` | `run` | Implemented | Inspect a stopped container's retained state. |
| `--process`, `--cwd`, `--env`, `--user` | `exec` | Implemented; see command details below for restrictions | Run another command with its own process configuration. |
| `--additional-gids`, `--cap` | `exec` | Implemented with the validation differences below | Give an exec process specific group access or capabilities. Useful when studying credentials. |
| `--ignore-paused` | `exec`; waits for resume | Implemented; also waits before forking | Queue an exec while a container is frozen. Optional for basic usage. |
| `--preserve-fds` | **`exec` only**; not registered for `run` or `create` | Implemented for `exec`, **plus `run` and `create` as runc-based extensions beyond the target** | Pass already-open files or sockets from a supervisor. Optional integration work. |
| `--pidfd-socket` | `run`, `create`, `exec` | Implemented for all three | Hand a race-resistant process handle to an external supervisor. Optional integration work. |
| Socket activation (`LISTEN_FDS`) | Init path used by `run`/`create`; environment behavior, not a CLI flag | Not landed. A separate draft is preserved, without Swift build or Linux runtime validation; deferred to the broader functionality milestone | Start a server with listening sockets supplied by a service manager. Optional integration work. |
| Terminal I/O, `exec --tty`, `--console-socket` | Implemented for terminal workloads | Detached terminals with `--console-socket` (create, `run -d`, `exec -d`, `exec --tty`) implemented and compared with runc, including through containerd's shim; the foreground terminal proxy is missing | Interactive shells and programs that require a terminal. More useful for ordinary interactive usage than descriptor handoff. |
| Foreground signal forwarding | Implemented | Missing; explicit `kill` is available | Deliver signals received by the attached runtime to its workload. Useful for attached command-line usage. |
| `--no-pivot` | `run`, `create` | Missing | Use an alternative rootfs transition when `pivot_root` is unsuitable. Later parity increment after ordinary engine bundles work. |
| `exec --cgroup` | Implemented | Missing | Place additional processes in sub-cgroups. Later parity increment for separate resource grouping. |

Evidence in the target: `src/nativeMain/kotlin/Main.kt` (`CreateCommand`, `RunCommand`, `ExecCommand`), `process/InitProcess.kt` (`LISTEN_FDS` handling), `command/Exec.kt`, `command/Foreground.kt`, and `console/Console.kt`. The target's activation code reads a positive `LISTEN_FDS` and supplies `LISTEN_PID=1`; it does not validate the caller's `LISTEN_PID`. Any future Swift activation implementation should document its runc-based semantics separately.

Namespaces, rootfs setup, lifecycle, credentials and basic resource controls provide the foundation. The next work is engine invocation/logging, practical mounts and supplied namespace joins, then a constrained containerd slice. Security and terminal support gate ordinary Docker use; hooks gate scenarios that request them. Socket activation is part of broader kontainer functionality, not a prerequisite for that first engine experiment.

## Commands

| Surface | Target behavior | Swift status |
| --- | --- | --- |
| `run` | Bundle, foreground wait/status/cleanup, detach, keep, PID file, console socket, pidfd socket, no-pivot | Foreground, detached, keep, PID file, `--preserve-fds`, and `--pidfd-socket` (label `standard`; empty value rejected) and `--console-socket` for detached terminals implemented; foreground terminals missing |
| `create`, `start`, `state`, `kill`, `delete`, `list` | Persistent transitions and process identity; named/numeric signals; kill-all; force deletion; table/JSON/quiet listing | Core lifecycle and create PID files implemented; shared-PID SIGKILL subtree cleanup and `--all` compatibility verified against runc 1.4. Non-KILL signals remain init-only, unlike kontainer's broader broadcast. Other optional flags remain missing |
| `pause`, `resume` | Cgroup freezer | Implemented with completion checks, kernel-derived paused state, identity protection, and Linux workload tests against runc |
| `update` | Resources file or stdin; individual resource flags; memory check-before-update | Implemented for supported memory/pids/CPU/cpuset fields, with saved merge semantics and Linux comparisons; other resource fields/flags remain, and failed-update rollback differs as documented in the [runtime reference](runtime-reference.md) |
| `events` | Stats snapshot or interval stream, OOM events, termination on deletion | Implemented for cgroup v2: runc's fs2 stats fields and units (CPU, throttling, memory/swap, raw `memory.stat`, pids, PSI, io byte/operation tables, hugetlb), unit-suffixed `--interval` such as `5s` or `1m30s` (default 5s), OOM events independent of the interval, stream end on cgroup exit or state deletion/recreation. `intel_rdt` and `network_interfaces` keep runc's empty `{}`/`null` (kontainer-runtime has no Intel RDT support and runc's network list is deprecated and always empty). OOM events report each `oom_kill` increase rather than every `memory.events` change, and out-of-range intervals are rejected |
| `ps` | Table/JSON output and verbatim trailing host `ps` arguments | Implemented, including descendant/threaded groups, lifecycle states, empty JSON null, and host-table filtering; compared with runc |
| `exec` | Command or process JSON; detach, terminal, console/PID/pidfd; cwd, env, user/groups, capabilities, preserved FDs, sub-cgroup, ignore-paused | Command and standalone process JSON forms implemented: existing namespaces/root/cgroup, foreground status, detach, PID files, cwd/env/numeric user overrides, appended `--additional-gids` (each given group once; runc 1.4.0-0ubuntu1 appends a lone group twice), bare `--no-new-privs`, repeatable `--cap` (ambient only where inheritable, unknown names rejected), configured process setup, runc-style `args[0]` lookup in the process PATH. `--ignore-paused` waits for resume before forking (as kontainer-runtime; runc forks into the frozen cgroup), failing if the container is deleted or replaced. `--preserve-fds N` passes caller descriptors 3..2+N, rejecting holes and close-on-exec descriptors before any state exists (runc passes any open descriptor and ignores negative counts); compared with runc in `scripts/preserve-fds-integration.sh`, which covers `create` and `run` too. `--pidfd-socket` sends label `setns`, compared with runc in `scripts/pidfd-socket-integration.sh` (also `create`/`run`). Terminals, `--no-new-privs=false`, and sub-cgroups remain. Socket activation is a separate init behavior, described above. Linux comparisons cover basic behavior; the detailed exec security matrix remains |
| `spec` | Generate default `config.json`; bundle and rootless options | Implemented as a generator following runc defaults, with runtime hostname and exclusive creation; its starter still requests runtime features listed below as missing |
| `features` | OCI feature JSON matching actual runtime support | Implemented; reports only currently implemented build features, with unsupported surfaces empty or disabled |
| Global options | State root, log path, text/JSON logs, debug | State root and global text/JSON error logs/debug implemented; real shim error extraction verified in [engine baseline](engine-baseline.md) |
| Version | Runtime version, commit, OCI specification version; `--version`/`-v` | Implemented with an explicit development version and OCI version; no commit line when build provenance is unknown |

Evidence: target `Main.kt`, `command/*.kt`, `state/State.kt`, and `config/KontainerConfig.kt`.

## OCI configuration and runtime behavior

| Area | Remaining target behavior |
| --- | --- |
| Process setup | HOME resolution; empty/omitted-process behavior; scheduling, I/O priority, exec CPU affinity, NUMA memory policy |
| Namespaces | Join supplied paths for types other than network; host/shared combinations; user and time namespaces (cgroup namespaces are implemented); UID/GID mapping handshake and mapping-helper fallback; time offsets |
| Rootfs and mounts | No-pivot; cgroup mounts without a cgroup namespace; explicit remount and broader propagation; dangling target symlinks and protected-proc bind handling; recursive attributes; idmapped mounts; custom character/block/FIFO devices with ownership/mode. Namespaced `linux.sysctl` and read-only cgroup2 mounts with a cgroup namespace are implemented |
| UTS and networking | Domainname; loopback setup; moving and renaming host interfaces. Hostname and new, unconfigured network namespaces already exist |
| Cgroup v2 | Only a subset is implemented: `linux.cgroupsPath`, memory `limit`/`reservation`/`swap`/`checkBeforeUpdate`, pids `limit`, CPU `shares`/`quota`/`period`/`burst`/`idle`/`cpus`/`mems`, adoption of one supplied path by at most one concurrent container, and cleanup at delete and on failure (see [runtime reference](runtime-reference.md)). Remaining implemented-target gaps: hugepages, unified controls, block-I/O weight/throttles, device-rule updates, update support for the other remaining controls, and sub-cgroups for `exec`. Track safe cleanup of owned ancestor cgroups as an integration task, not a target feature claim. Legacy memory fields, CPU realtime, network/RDMA resources and `blockIO.leafWeight` are not implemented-target requirements; see the exclusions below. Unsupported Swift resource fields are rejected, not ignored. |
| Security | Complete init/exec policy verification; positive SELinux application and key-label evidence (AppArmor confinement, availability refusal and key-creation staging are implemented); sealed executable handoff |
| Seccomp | Notification listener handoff and its flags; broader architecture execution evidence. Non-notification actions, compat-ABI filter generation, all argument operators, runc-style AND/OR rules and TSYNC/LOG/SPEC_ALLOW flags are implemented. |
| Hooks | All six phases, environment, state on stdin, timeout and failure semantics |
| Foreground and descriptors | Signal forwarding, foreground terminal I/O/resizing, socket activation (`LISTEN_FDS`). Console handoff to `--console-socket` is implemented. Inherited descriptors from 3+N up are marked close-on-exec; `--preserve-fds N` is implemented |
| Portability and integration | x86_64 Linux; real musl/static build and execution; applicable runc compatibility tests. Experimental Docker support passes the acceptance gate on one arm64 Ubuntu cgroupfs profile (see [Docker integration](docker-integration.md)) |

The current foreground and persistent lifecycle subset has real Linux debug/release evidence for PID 1, pivoted rootfs, proc/tmpfs/devpts, standard devices, hostname, cwd, explicit environment, stdio, status propagation, rejected configurations, descriptor cleanup, lifecycle transitions, concurrent create/start, signal delivery, stale process identity protection, and failure cleanup. Process credentials (uid, gid, additional groups including clearing, umask with runc's default, and no-new-privileges) are compared with runc from inside the workload in foreground, detached, and create/start modes; the detailed exec credential/security matrix, user-namespace mappings, and `/proc/self/setgroups` deny handling remain. Exec already reuses `WorkloadSetup` for credentials, capabilities and rlimits; implementation and complete verification are separate statuses. The five capability sets (absent, `{}`, configured root and non-root with ambient and no-new-privileges, and an inherited inheritable capability kept outside a reduced bounding set) are compared with runc through `/proc` masks and allowed/denied operations in the same three modes, and a set the kernel refuses fails under both; this runtime rejects the unknown names, kernel-unsupported numbers, and ambient requests runc only warns about. Rlimits (absent, configured root and non-root, repeated types applied in order, raised hard limits, and infinity) are compared with runc in the same three modes, both through the workload's `getrlimit` values and through the created init's `/proc/PID/limits` right after `create`. `RLIMIT_NOFILE`, `RLIMIT_FSIZE`, and `RLIMIT_CPU` enforcement is compared too, and refused, invalid, and unknown entries must fail under both without leaving state or processes. A waiting init's `RLIMIT_NOFILE` is the one value not compared, and only when the config omits it (even if it configures other rlimits), because runc's Go bootstrap raises it until `execve`. Its workload's value is compared. With tiny `RLIMIT_NOFILE` and `RLIMIT_AS`, both runtimes must hold and enforce the limits and clean up. Whether each runtime's own bootstrap fits under them is recorded rather than required to match, since that reflects runtime overhead rather than OCI semantics. Deliberate differences: a missing `soft`/`hard` is rejected (runc decodes 0), and soft above hard is rejected before launch (runc fails at `prlimit`). Read-only roots are verified against runc with exact EROFS checks, writable child mounts, created-init mount flags, and unchanged host contents and mount permissions in Linux debug/release. This runtime also preserves inherited root mount security flags. Masked and read-only paths are compared with runc as root and uid 1000 in the three modes, with and without `root.readonly`, through exact errno names, contents, device numbers and inode identity, created-init mount tables, and host isolation. `readonlyPaths: ["/"]`, configurations without `/proc`, and all-missing paths are compared too. Deliberate differences: paths with `.`/`..` components are rejected (runc cleans them lexically), magic links fail with `ELOOP` (runc follows them), a mask its path does not show (such as one on `/`) fails setup, and read-only paths need Linux 5.12+ for `mount_setattr`. Setup assumes a single owner of the rootfs; it is not race-free against a concurrent host writer. It does not establish the remaining behavior above.

Evidence paths in the target, relative to `src/nativeMain/kotlin/`:

- Process: `spec/Spec.kt`, `process/InitProcess.kt`, `process/ProcessSecurity.kt`, `process/{HomeResolver,Scheduler,IOPriority,CpuAffinity}.kt`, `command/Exec.kt`.
- Namespaces: `command/Create.kt`, `process/MainProcess.kt`, and `src/nativeInterop/cinterop/bootstrap/bootstrap.c` (the last path is relative to the repository root).
- Mounts/network: `rootfs/Rootfs.kt`, `process/InitProcess.kt`, `process/MainProcess.kt`, and native network interop.
- Resources: `cgroup/{CgroupV2,DeviceCgroup}.kt`, `command/Update.kt`.
- Security/integration: `hook/Hook.kt`, `seccomp/*.kt`, `process/SessionKeyring.kt`, `exeseal/ExeSeal.kt`, `command/Foreground.kt`, `console/Console.kt`.

## What is not evidence of a parity requirement

The target mentions checkpoint/restore in help names but does not register or implement those commands. Its `--systemd-cgroup` option explicitly reports that it is unimplemented, and its resource implementation uses cgroup v2. Checkpoint/restore, cgroup v1, and systemd-managed cgroups are therefore outside this target's implemented functionality.

The pinned target's `spec/Spec.kt` and `CgroupV2.applyResources` establish memory limit/reservation/swap, CPU shares/quota/period/burst/idle/cpus/mems, pids, hugepages, unified settings and block-I/O weight/throttles. `command/Update.kt` applies the memory check-before-update; device rules are applied separately by `DeviceCgroup`. Legacy memory fields (`swappiness`, `kernel`, `kernelTCP`, `disableOOMKiller`, `useHierarchy`), CPU realtime fields, and network/RDMA resource classes are not implemented there and do not belong on the parity backlog.

Likewise, `linux.mountLabel` and `blockIO.leafWeight` appear in its schema without applying consumers. AppArmor and SELinux have staging code while its feature report says they are disabled; parity needs platform-aware availability and error tests rather than an unconditional support claim.

A feature becomes complete only after its implementation and relevant observable behavior have been checked. Passing a narrow fixture or matching a CLI name is not full feature parity.

## Consumer compatibility versus feature breadth

A kontainer-level implementation does not by itself certify Docker compatibility.
The existing containerd runc shim consumes CLI logging, detached PID publication,
process JSON, stdio and console FDs, reparented children, kill-all and cleanup
contracts. Match these where the tested consumer relies on them. Preserve Swift
formatting choices where JSON values and required keys suffice; do not reproduce
incidental runc internals. The [Docker gap assessment](docker-integration.md)
records the blockers, versioned sources and end-to-end acceptance gates.

Sysfs, mqueue and tmpfs-based `/dev/shm`, including `ro`/`rw` mount flags, now
have focused Linux debug evidence through run/create/start/exec against runc.
The probe checks sysfs's private network view, private IPC message queues,
read-only enforcement, safe failure on a symlinked sysfs target and cleanup.
See [engine baseline](engine-baseline.md). Bind mounts and supplied network paths
have follow-up evidence below; cgroup mounts and other namespace paths remain gaps.

Nonempty `linux.resources.devices` now produces an enforced cgroup-device BPF
filter before init joins its cgroup. The rule normalizer preserves runc's reset,
permission merge and default-device ordering; unsupported wildcard holes fail.
Ancestor filters remain effective and cleanup detaches only the recorded owned
program. Other resource updates retain the policy; requested live device-rule
updates are rejected explicitly. Kernel enforcement, denied opens/mknod, adopted
and inherited filter ownership, failed setup, and init/exec are checked on Linux.
A partial deny rejects any overlapping access, including combined read/write,
which is deliberately stricter than runc 1.4's subset test for combined requests.
The [engine baseline](engine-baseline.md) now includes the successful constrained
containerd directory-rootfs scenario and its remaining exclusions.

File/directory bind and rbind mounts now support confined existing target links,
missing target files/parents, source paths relative to the bundle, explicit VFS
attribute clears and private/rprivate propagation. `rbind,ro` changes the top
mount only; submounts keep their attributes. Unmentioned inherited attributes
remain set, which can be stricter than runc 1.4's first remount attempt. The bind
suite compares ordinary cases with runc and checks host mount tables, descriptor
closure and failure cleanup. Early source pinning and prevention of device-node
creation in a host-backed `/dev` have Swift-specific regressions. A pinned Alpine
3.23.6 native-snapshotter run through containerd also passes file/volume binds and
init/exec cleanup. Absolute supplied network paths now work through proc links
and bind-mounted nsfs files, with type validation and launcher-only joining.
Linux comparisons cover private TCP, create-time namespace identity, exec after
source-path removal, caller isolation, descriptor closure and failed-join cleanup.
The pinned Alpine image also passes containerd-provided network joining and TCP
through exec. Other namespace joins, cgroup namespaces and bridge/DNS remain open.

Seccomp now uses the host libseccomp system library. Focused Linux debug tests
compare root/non-root init and exec, both no_new_privs modes, argument comparisons
(including 64-bit values and AND/OR), errno/trace/log/termination actions, retained
policy after bundle edits/removal and rejected loads against runc. Containerd's
default profile and a custom getcwd-denial profile pass the pinned Alpine image
scenario. Notification, runc's future-syscall ENOSYS fixups, cross-ABI execution,
other architectures and static/musl packaging remain outside this evidence.
See [engine baseline](engine-baseline.md) for the exact profile and checks.

`process.oomScoreAdj` now has focused Linux debug comparisons with runc for
root/non-root init and exec, both range bounds, explicit zero, absent/null and
nonzero inherited scores. The launcher writes procfs before namespace and
credential changes; original container policy survives bundle edits/removal and
ignores standalone-process overrides, as in runc. Negative writes without
CAP_SYS_RESOURCE and out-of-range values fail without workloads, state or cgroups.

Session keyrings now default to runc-style `_ses.<id>` sessions, owner-search
permission setup, and exec joining. Focused Linux comparisons cover root/non-root
init/exec identity, caller-key exclusion, separate live container IDs, shared
container keys, bundle removal and persistent `--no-new-keyring` behavior. Swift
failure probes cover join/permission denial and ENOSYS, failed-exec isolation and
legacy state. Unlike runc's ENOSYS fallback, Swift requires explicit opt-out when
keyrings are unavailable. A requested SELinux label also sets the key-creation
context before the join; see the LSM notes below.
The pinned image also passes session identity/shared-key checks through containerd;
its default/custom seccomp gates still pass with keyring setup enabled.

AppArmor and SELinux process labels are now applied rather than rejected:
runc's ordering stages both exec contexts for the workload's execve, a SELinux
label sets the key-creation context before the session-keyring join, and exec
uses process-file overrides or the recorded container labels. Unlike runc and the
pinned target (whose staging failures are only logged), a requested module the
host does not enable fails before launch. `linux.mountLabel` is not applied by the
target either and is rejected when nonempty. The `lsm` suite covers availability
refusal, empty labels, exec refusal and cleanup on a host without either module.
On an Ubuntu AppArmor host, direct runc comparisons and containerd's generated
default profile verify init/exec confinement; SELinux has no positive evidence yet
(see the engine baseline).
