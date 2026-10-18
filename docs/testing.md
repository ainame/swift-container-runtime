# Development and testing

Build instructions and detailed Linux integration coverage.
For an introduction, see the [README](../README.md). Run commands from the repository root.

## Toolchain and checks

The package requires Swift tools 6.4. `.swift-version` selects the macOS 6.4.0 release without changing your global toolchain. Linux tests use the explicit `swift:6.4.1` image and a separate build directory. `Package.resolved` records the CLI dependency resolution.

```sh
swift test
```

Strict memory diagnostics and warnings-as-errors are package settings, so ordinary builds and tests enforce them automatically. GitHub Actions runs the unit tests and debug/release namespace, OCI, lifecycle, credential, and capability checks in the pinned Swift 6.4.1 Linux image.

## Validation tiers

Use the smallest check that exercises the change, then broaden at review. Release
checks belong to review or milestone completion, not every edit or meaningful
commit. Strict memory safety and warnings-as-errors stay enabled in both modes.

| Stage/change | Default checks | Broaden when |
| --- | --- | --- |
| Documentation only | Links/examples and `git diff --check`. | A runnable example or script changes: check that interface too. |
| Parsing, planning, CLI, portable helpers | Relevant debug unit tests, e.g. `swift test --filter RuntimeCommandTests`. | Shared decoding or public API changes: run the unit suite. Linux-only behavior also needs a focused Linux check. |
| Runtime feature implementation | Debug unit tests plus the affected Linux integration suites. | Shared launch, descriptor lifetime, credentials, mount ordering or state ownership changes: include lifecycle/OCI and the suites that exercise the affected invariant. Broad refactors warrant the full debug suite. |
| Review / milestone candidate | Complete debug and release unit/integration matrix once on the candidate, locally **or** in CI. | Relevant code changes after the pass: rerun affected checks; optimization-sensitive changes invalidate the relevant release evidence. A broad rebase or shared launch rewrite may justify the full gate again. |
| Engine support claim | Actual containerd/Docker scenario on its declared profile, in addition to relevant runtime checks. | Engine version/profile or contract changes. A docs change does not establish support. |

Do not run `swift build` immediately before an equivalent `swift test`; tests
build their dependencies. Do not repeat a successful local full gate just to
obtain the same result in another environment; use the existing CI review gate
where suitable and distinguish passed, pending and unrun checks. Commits made
during implementation can explicitly say release validation is deferred to review.
The current CI runs the full matrix for PRs and main; there is no requirement to
reproduce it locally before every commit.

For targeted Linux runs, select suites by behavior rather than running every
suite because a shared file was touched:

| Change | Starting integration selection |
| --- | --- |
| Launch/start/exit, process identity or cleanup | `oci lifecycle`; add `kill` for signal/cgroup-subtree cleanup; add suites for changed setup or descriptor invariants. |
| Mount/rootfs/path controls | `oci readonly path-controls`; add `filesystems` for sysfs/mqueue/shm and `bind` for bind sources/targets/flags; add `lifecycle` for readiness/cleanup changes. |
| Supplied network namespace | `network-namespace oci lifecycle preserve-fds`. |
| Session keyrings / default launch security | `keyring oci lifecycle credentials capabilities preserve-fds`, plus the opt-in keyring and seccomp image gates. |
| OOM adjustment | `oom network-namespace seccomp oci lifecycle preserve-fds`. |
| Hooks | `hooks lifecycle oci console`; launch-handshake changes also need `pidfd-socket preserve-fds`. |
| Sysctls / cgroup namespaces | `sysctl cgroupns oci lifecycle`; `readonly` checks the namespace refusal. |
| Docker-facing contract | The opt-in `docker-integration.sh RUNTIME IMAGE` gate on a host with Docker and the cgroupfs driver; run it with `runc` too. |
| Terminals/console socket | `console pidfd-socket lifecycle oci`; the opt-in `containerd-console-integration.sh` gate checks attached engine terminals. |
| AppArmor/SELinux labels | `lsm keyring oci lifecycle`; on an AppArmor host also the opt-in `apparmor-integration.sh` and `containerd-apparmor-integration.sh` gates (see the [engine baseline](engine-baseline.md#requested-apparmor-and-selinux-labels)). |
| Seccomp policy/setup ordering | `seccomp oci lifecycle credentials capabilities preserve-fds`. |
| Credentials/capabilities/rlimits | `credentials capabilities rlimits`; add `lifecycle lookup` for ordering/exec changes. |
| Inherited FDs or socket handoff | `preserve-fds pidfd-socket lifecycle`. |
| Cgroup resources | The changed controller's suite (`cgroup`, `cpu`, `cpuset`, `devices`), plus `update`; add `freezer ps events` if membership/reporting changes. |
| Metadata/CLI output | `metadata`, `logging` and affected unit tests. |

These are starting selections, not mandatory bundles for every edit. Add one
regression case for the new behavior and relevant failure/cleanup paths. Expand
root/non-root, lifecycle-mode and platform combinations at feature review where
they exercise different mechanisms. Avoid a Cartesian product for every new flag,
exact diagnostic/formatting assertions unless a consumer relies on them, or new
runc comparisons merely to reproduce an already documented incidental difference.

`features` prints the OCI feature report for the current build. `--version` and `-v` print its development version and target OCI version; a commit is omitted when it is unknown. `spec --bundle PATH` writes a runc-style starter `config.json`, and `--rootless` generates the user mappings for the calling user. The generated starter includes terminal, mount, device, and namespace features this runtime still needs to implement, so it requires editing before use here. Existing configuration entries are never overwritten, including dangling symlinks; runc can write through a dangling symlink. `scripts/metadata-integration.sh` checks command output and compares generated specifications with runc as root and uid 1000.

## Development on macOS

See [code organization](code-organization.md) for responsibility boundaries, naming, and launch lifetime constraints.

The commands perform Linux kernel operations; macOS builds (macOS 27 or later) compile all of the runtime, so the compiler checks the Linux code, but cannot run containers or the namespace lab. Unit tests for configuration decoding, validation and the portable Kernel operations run on macOS. Use a Linux VM or Apple's [`container`](https://github.com/apple/container) command to build and test the Linux executable.

Start with focused Linux debug checks from macOS:

```sh
container system start
scripts/test-linux.sh lifecycle oci
```

The script uses a disposable VM-backed `swift:6.4.1` container and stores Linux build products separately in `.build/linux-6.4.1`. Debug is the default; `--configuration release` selects optimized checks and `--configuration all` runs both. Integration suites cover namespaces, procfs, surrounding hostname/mount preservation, exit and signal status, argument handling, permission failures, and parent-death cleanup.

Select the suites affected by a change; an explicit debug configuration is optional. Unit tests still run, and selected integration suites still compare with runc:

```sh
scripts/test-linux.sh --list
scripts/test-linux.sh --configuration debug lifecycle update
```

With no suite arguments the script runs every integration in debug. Use `scripts/test-linux.sh --configuration all` for the complete review gate; CI also runs both configurations. Both use the same suite inventory in `scripts/run-integration.sh`, which reports each suite's duration and stops on the first failure. On an already prepared Linux host, run `scripts/run-integration.sh .build/debug/srunc update` to reuse its installed fixtures and build. Suite names are checked before a local VM starts. New integration suites must be added to that shared inventory.

Inside the VM it also installs `busybox-static` and `runc` and runs `scripts/oci-integration.sh`. That script builds a static BusyBox rootfs and runs the same bundles through this runtime and runc. Both must satisfy the shared checks: PID 1, rootfs contents and isolation from host files, hostname, cwd, environment replacement, device nodes, separate stdout/stderr, exit 42, and missing executables. Runtime-specific checks cover exit 125 diagnostics, rejected configurations, symlink escapes from mount destinations (absolute and relative), and setup failures after partial mounting. Those failures must not run the workload or change host mounts and hostname. Set `RUNC_COMPARE=0` to skip runc, or `RUNC_COMPARE=1` to require it.

`scripts/lifecycle-integration.sh` then runs the lifecycle against both runtimes (`RUNC_COMPARE=1` in the VM and CI): a created init is PID 1 in the prepared rootfs and has not run the workload; created, running, and stopped transitions; a single start; TERM reaching a handler and KILL; real exits; invalid transitions; `delete --force` leaving no process of the PID namespace; duplicate IDs; detached and foreground `run`; and renamed or removed bundles. Runtime-specific checks cover exact messages, concurrent starts and creates, `list` formats, create-time and start-time exec failures, descriptor isolation, foreground parent-death cleanup, and stale or tampered state that must not signal an unrelated process. Failed create and foreground run clean up their state and processes. An exec failure during `start` leaves stopped state for inspection and deletion; abrupt CLI termination can also leave stopped metadata. A fixture start client dies at each handshake step: before its request, after it, after acceptance (all leave the container created), and after unlinking `start.sock` without committing (stopped, nothing runs).

`scripts/lookup-integration.sh` compares `process.args[0]` lookup with runc through foreground `run`, `create`/`start`, `exec` commands, and standalone process JSON, with the caller's `PATH` set to a directory that exists only in the rootfs: later candidates after directories, non-executable files, and non-directory prefixes; in-root symlinks; the last `PATH` entry and exec `-e PATH`; root and uid 1000 permissions; missing, empty, relative, and empty-element `PATH` (refused like Go's `ErrDot`); explicit absolute and cwd-relative paths; unknown commands with cleanup; preserved `argv[0]`; and an executable removed between `create` and `start`.

`scripts/credentials-integration.sh` runs probes as uid 1000 with groups, umask `0077`, and `no_new_privs`; as uid 1000 without groups or umask; and as root with an empty group list. Each runs in foreground `run`, detached `run`, and `create`/`start` under both runtimes, from a caller that has its own supplementary groups and umask `0077`. The workload records its own `/proc` credentials, umask, `NoNewPrivs`, and capability sets, the owner and mode of a file it creates, whether group membership grants a group-only file, the effective uid gained through a setuid-root executable, and whether it can reopen `/dev/stdout`. The records must match the expected values, including empty permitted, effective, and ambient capability sets for non-root users. The credential, umask, `NoNewPrivs`, group-access, setuid, and (inherited, since these configs have no `process.capabilities`) capability fields, and the created file's owner and mode, must also match runc's. A created init must already hold the credentials when `create` returns. A root-only executable must fail non-root `create` and `run` under both runtimes. Runtime-specific checks cover the exact permission error, non-root foreground parent-death cleanup, a detached non-root container outliving its CLI, and descriptor isolation. Under both runtimes it also execs into a running uid 1000 container with configured group 2000: no flags keep the group and `NoNewPrivs: 0`; `-g` appends groups, `--no-new-privs` sets the flag, `-u 0:5` combines with both; `--process` ignores the flags; and a failed exec leaves the init's credentials unchanged. Invalid `-g` values fail exec without stopping the init.

`scripts/capabilities-integration.sh` runs from a caller holding an inheritable and ambient `CAP_NET_RAW`, in foreground `run`, detached `run`, and `create`/`start` under both runtimes, with `process.capabilities` absent, `{}`, configured for root, configured for uid 1000 with an ambient `CAP_CHOWN` and `no_new_privs`, and configured for uid 1000 to keep the caller's inheritable `CAP_NET_RAW` (also permitted, effective, and ambient) while bounding holds only `CAP_CHOWN`. A root config asking for an inheritable capability that is neither in bounding nor inherited must fail under both runtimes. The workload records its `/proc` capability masks and whether it may give away a file (`CAP_CHOWN`), set the hostname (`CAP_SYS_ADMIN`), and read another uid's mode-0600 file (`CAP_DAC_OVERRIDE`). Records and the created inits' masks must equal the expected values and runc's. The configured root case shows Linux's root `execve` rule: the workload's permitted and effective sets become bounding ∪ inheritable, whatever permitted and effective were. Runtime-specific checks cover unknown-name and ambient-subset rejection, the `capset` refusal diagnostic, the kernel-range rejection when `cap_last_cap` is below 40, the diagnosis when the caller lacks `CAP_SETPCAP` (and that an absent object does not need it), root and non-root foreground parent-death cleanup, detached lifetime, and descriptor isolation without capabilities. Under both runtimes it also execs into running root and uid 1000 containers with and without repeated `--cap`, checking masks and operations (a requested inheritable capability becomes ambient, others do not), that a process file's `{}` wins over `--cap`, and that successful and failed execs leave the init's sets unchanged; unknown `--cap` names must fail here. setuid-binary interactions with configured sets are not exercised.

`scripts/readonly-integration.sh` mounts a `nosuid,nodev` tmpfs for the rootfs and links `scripts/fixtures/readonly-probe.c` statically into it. The probe reports exact errno names for real writes. With `root.readonly` `true`, under both runtimes, as root and as uid 1000, in foreground `run`, detached `run`, and `create`/`start`, writing an existing world-writable file and creating a file or directory must fail with `EROFS`. Creating, writing, and making directories in a `/scratch` tmpfs (and, as root, in `/dev`) must succeed, and a missing `process.cwd` must be created. With `false` or absent, the same writes must succeed as the same users, so `EACCES` cannot pass for `EROFS`. The host file is checked unchanged after denied writes, and the host mount is checked writable afterwards and while a created init waits. That init's `/proc/PID/mountinfo` must already show `/` read-only. Probe records must match runc's, except the root mount flags. This runtime must keep `nosuid,nodev`; runc's result is logged. Setup failures (a missing program and the still-rejected `linux.sysctl`) must not time out and must leave no state or process.

`scripts/path-controls-integration.sh` links `scripts/fixtures/path-probe.c` statically into a rootfs on a `nosuid,nodev` tmpfs and configures duplicate, repeated, nested, missing, below-mask, and symlinked (in-root and climbing) read-only and masked paths. Under both runtimes, as root and uid 1000, in foreground, detached, and `create`/`start` modes, with and without `root.readonly`, the probe must see masked files as empty, writable 1:3 devices with `/dev/null`'s inode, masked directories as empty read-only tmpfs mounts with `EROFS` for creates, `EROFS` for writes to read-only and nested read-only paths with `nosuid,nodev` kept, a writable tmpfs below a read-only path, writable unrelated paths unless the root is read-only, and `ENOENT` where a climbing symlink would land. Proc masking uses `/proc/version`, which always exists, and `/proc/kcore`, which must be masked when the host kernel provides it and be absent otherwise. `readonlyPaths: ["/"]` is compared with runc and logged against `root.readonly`, with writable child mounts required; read-only-only and all-missing configurations without `/proc` must match runc exactly. Masks without `/proc` must work here; runc mounts masks through `/proc/thread-self/fd`, so the installed runc must fail them with exactly `can't mask path "/data/secret": mount dst=/data/secret, dstFd=/proc/thread-self/fd/N, flags=MS_BIND: no such file or directory` (version logged, any other failure is an error, and a runc that succeeds must match this runtime's record), and this runtime's output is compared with runc running the same controls plus a `/proc` mount, differing only in `/proc` visibility. Records must match runc's except directory-mask sharing and root mount flags that inherit runc's `root.readonly` remount. The checked-out runc reference shares one tmpfs between masked directories and applies a repeated masked path once; the installed runc package (observed: 1.4.0-0ubuntu1) mounts one tmpfs per directory and mounts a repeated masked file again. This runtime must follow the reference, and runc's results are logged. A created init's mount table must show every applied path and none of the skipped ones. Its per-mount-point counts must equal the reference-derived counts here, and match runc's exactly, including repeated recursive read-only binds; the only exception is the repeated masked file's count, excluded only when runc's own counts show it mounted twice. Host contents are compared byte for byte, and host writability, mount flags, and mount table are checked after every run. Setup failures (a non-directory component after earlier paths were applied, under both runtimes; magic links, a regular-file or missing `/dev/null`, a mask on `/`, `..`, and an unknown field, under this runtime, with runc's `maskedPaths: ["/"]` outcome logged) must report the exact stage and errno and leave no state, process, mount, or host change.

`scripts/cgroup-integration.sh` needs a writable cgroup v2 hierarchy. Test cgroups live under one `/sct-PID` subtree that is removed afterwards. There are two exceptions. The default-path smoke check creates, and then deletes, its own container's `/swift-container-runtime/<id>` cgroup. In the VM, the setup also uses a `/runner` leaf. The caller must already have `memory` and `pids` enabled in the root's `cgroup.subtree_control`; the script fails otherwise. In the disposable VM, `scripts/test-linux.sh` first moves its own top-level shell into a `/runner` leaf, then enables them. A namespace root with member processes cannot delegate controllers. In CI, the privileged job container uses `--cgroupns=host`, so its root is the runner VM's systemd-managed root, which already delegates both. The script moves only its own sleeps, and only the containers and processes it starts are signalled. A separate bystander cgroup checks that nothing else is touched. It links `scripts/fixtures/cgroup-probe.c` statically into the BusyBox rootfs. Under both runtimes, in foreground `run`, detached `run`, and `create`/`start`, as root and as uid 1000, it checks four things:

- The init's `/proc/self/cgroup` names the configured path.
- `memory.max`, `memory.low`, `memory.swap.max`, and `pids.max` hold runc's reference values (67108864, 16777216, 33554432, 16) when `create` returns.
- A pids limit of 16 stops forking at exactly 15 children with `EAGAIN`.
- With a 32 MiB limit and no extra swap, a 256 MiB allocation is OOM-killed (`oom_kill` must rise) without timing out.

Further checks cover pids 0 and -1, a threaded parent (pids succeeds, memory fails), and a swap below the memory limit (rejected). Without a PID namespace, a descendant must be killed at delete, and `delete --force` must remove a process tree. Several containers get their own limits. Each run's values file must match runc's byte for byte, including the case with a pids limit of 0. There is no exemption. Runtime-specific checks cover:

- Rejection of `linux.resources.cpu.realtimeRuntime`.
- No leftover cgroup after a failed exec.
- Removal of the default `/swift-container-runtime/<id>` cgroup.
- A pre-existing empty cgroup that is used and kept, and a busy one that is refused.
- Two containers created at once in one supplied cgroup, with pids limits 8 and 12, over eight rounds. Exactly one may succeed, without timing out. The loser must fail with the contention or non-empty error and leave no state. The cgroup must hold exactly the winner's init with the winner's limit.
- Warnings that leave the cgroup alone when it was replaced at the same path or recorded under another boot ID.

A separate bystander cgroup with its own process must be unchanged at the end.

`scripts/cpu-integration.sh` has the same delegation requirements, with `cpu` enabled in the root's `cgroup.subtree_control` (`scripts/test-linux.sh` enables it with `memory` and `pids`), and uses its own `/sct-cpu-PID` subtree. It links `scripts/fixtures/cpu-probe.c` statically into the BusyBox rootfs. Under both runtimes, in foreground `run`, detached `run`, and `create`/`start`, as root and as uid 1000, the init must be in the configured group and `cpu.weight`, `cpu.max`, `cpu.max.burst`, and `cpu.idle` must hold the configured values when `create` returns. Further cases cover absent and zero values, the shares conversion (2, 3, 1024, 2048, 262143, 262144, and the 64-bit maximum), default and unlimited quota and period, the kernel's minimum and maximum, burst ordering and its retry after `cpu.max`, idle with and without shares, values the kernel refuses, an unavailable controller, and a threaded subtree. Burst and idle cases run only when the kernel provides `cpu.max.burst` (5.14+) and `cpu.idle` (5.15+); otherwise their absence must fail setup. Quota enforcement is proved by real CPU work: under a 20% quota, 300 ms of CPU time must take at least twice as long and the group's `cpu.stat` must show throttling, against an unthrottled control. Every values file must match runc's byte for byte, with no exemption. Weight fairness between groups is not measured; the weight is checked only by readback. This runtime alone is also checked for enabling only `cpu` for CPU-only groups, rejecting the realtime fields, and leaving a bystander group unchanged.

`update ID` changes the supported memory, pids, CPU, and cpuset controls of a created, running, or paused container. Use `--resources FILE` or `--resources -` for a `linux.resources` JSON object; when provided, it takes precedence over individual resource flags, as in runc. Flags include `--memory`, `--memory-swap`, `--memory-reservation` (binary RAM units such as `128m`), `--pids-limit`, `--cpu-quota`, `--cpu-period`, `--cpu-share`/`--cpu-shares`, `--cpu-burst`, `--cpu-idle`, `--cpuset-cpus`, and `--cpuset-mems`. Saved resource settings survive removal of the bundle. Quota-only and period-only requests retain their old counterpart; an empty request clears both in saved metadata while leaving the kernel value unchanged, matching runc's subsequent merge behavior. Legacy records without saved settings remain readable but must be recreated before updating.

`memory.checkBeforeUpdate` rejects a positive limit at or below current usage before writing memory controls. As in runc, the check uses `memory.current` even for memory+swap and is best effort when usage cannot be read. Updates are not atomic kernel transactions: failed writes attempt to reapply the old settings, and a rollback failure is reported. One observed difference is intentional: after a memory-check failure following a pids write, Swift restores the previous pids limit; installed runc 1.4's shallow configuration sharing leaves that pids write applied and reports rollback failure. `scripts/update-integration.sh` asserts each outcome explicitly and checks controller enablement, stale/legacy records, file/stdin precedence, live affinity restrictions, and CPU throttling after updates against runc.

`ps --format json ID` lists host PIDs from the verified cgroup and descendant groups, including paused processes and a created init. An empty snapshot is `null`, matching runc. Table mode runs host `ps -ef`, or forwards every argument after the container ID verbatim (for example `ps ID -e -o comm,pid --sort=-pid`), then filters rows by the header's `PID` column while preserving their spacing and order. Resource/state descriptors are closed before `posix_spawnp`; Swift is not forked. A stale cgroup identity contributes no foreign PIDs. `scripts/ps-integration.sh` compares actual cgroup membership, descendant and threaded groups, lifecycle states, table filtering, and option forwarding against runc.

`events [--interval DURATION] [--stats] ID` prints runc-compatible JSON lines for a created, running, or paused container; a stopped one is refused, as is a nonpositive interval. `--stats` prints one `stats` event immediately. Otherwise a `stats` event follows every interval (a duration such as `5s`, the default, `300ms` or `1m30s`), the first one interval after the start, and an `{"type":"oom","id":ID}` event follows each increase of `memory.events` `oom_kill` as soon as inotify reports it, independent of the interval. The stream ends with status 0 when the cgroup empties or `cgroup.events` becomes unreadable (as runc's notifier does), or when the container's state directory is deleted or its record names another cgroup generation; an atomic `state.json` rewrite by `update` does not end it. No lock is held while waiting, and every read goes through the cgroup directory pinned and checked against the recorded boot ID and inode, so a recreated cgroup is never reported.

Statistics follow runc's fs2 manager: CPU usage and throttled time in nanoseconds (from `cpu.stat` microseconds), memory usage/limit/peak, memory+swap usage and limit as runc reports for cgroup v1 compatibility, the `memory.stat` map and its `file` value as `cache`, `pids.current` (counting `cgroup.procs` without the pids controller) and `pids.max` (`max` is 0), PSI for CPU, memory, and I/O where the kernel provides it, `io.stat` byte and operation counts, and hugetlb usage and failure counts per page size. Missing controller files leave their values empty, as in runc; other read errors fail the snapshot as root and are ignored otherwise, as runc does for rootless containers. During a stream, a failed sample is reported on stderr and the stream continues. `intel_rdt` and `network_interfaces` print as `{}` and `null`, runc's values without Intel RDT and for its deprecated, always-empty network list.

OOM events are reported for each new kill rather than for every `memory.events` change once any kill has occurred. Without the memory controller, no OOM events are produced until an update enables it. A running stream then attaches OOM monitoring within about 100ms and reports kills during activation. Intervals whose components exceed the supported duration range are rejected.

`scripts/events-integration.sh` parses each event's JSON fields and compares with runc, as root and uid 1000: snapshots, paused snapshots against frozen kernel readback, interval validation, CPU counter growth in a stream that continues across pause and resume, accepted, rejected, and unlimited updates, prompt OOM events under an hourly interval, and stream ends on exit and on forced deletion at hourly and 1ns intervals. It also checks that a stale cgroup record and a container deleted and recreated under the same ID end a stream without reporting the replacement or a bystander, and that a stream started without the memory controller reports a real OOM kill after an update enables it.

`pause ID` freezes a running container or a created init at its start gate, using `cgroup.freeze` and waiting up to 10 seconds for `cgroup.events` to confirm every task is frozen. `resume ID` thaws a paused container; an init still at its start gate returns to `created`. `state` and `list` derive `paused` from the verified live init and recorded cgroup, retaining its PID. SIGKILL and forced deletion thaw the group so tasks can exit. Both commands check the recorded boot ID and inode before writing. `scripts/freezer-integration.sh` compares transitions and real counter workloads against runc, as root and uid 1000 in foreground, detached, and create/start modes, including frozen deletion, stale cgroup records, and an unaffected bystander.

`scripts/cpuset-integration.sh` reuses the CPU fixture's lifecycle and cleanup helpers. It compares CPU/node list readback and inheritance with runc, checks effective sets before `create` returns, and runs root and uid 1000 workloads in all three lifecycle modes. A static affinity probe verifies the configured single-CPU mask, an allowed affinity change, and `EINVAL` when requesting an excluded CPU if the host offers one. Empty lists preserve supplied groups; invalid lists fail setup and clean up. CPUs and nodes are selected from the test hierarchy's effective sets. NUMA page placement is not measured.

`scripts/rlimits-integration.sh` links `scripts/fixtures/rlimit-probe.c` statically into the BusyBox rootfs. The probe is a test fixture that reports `getrlimit` values, `EMFILE`, `EFBIG`, `SIGXCPU` (it checks that 0.8–2.0 seconds of process CPU time had been used when the signal arrived, and treats an out-of-range time or its wall-clock guard expiring as a failure), and `ENOMEM` from an address-space reservation. The script runs from a caller with fixed limits (`RLIMIT_NOFILE` 256:512, `RLIMIT_CORE` 0:0, `RLIMIT_MEMLOCK` 65536:65536). Under both runtimes, in foreground `run`, detached `run`, and `create`/`start`, as root and as uid 1000: an absent list must leave all sixteen limits equal to the caller's. A configured list must give exactly the configured values, with unconfigured resources inherited. That list repeats `RLIMIT_NOFILE` (lowered, then raised above the caller's hard limit), raises hard limits to unlimited, and sets `RLIMIT_NPROC`. A created init's `/proc/PID/limits` must hold the configured values as soon as `create` returns. Enforcement under both runtimes covers `RLIMIT_NOFILE` 16 (exactly 13 more descriptors), `RLIMIT_FSIZE` 4096 (a short write and then `EFBIG`), and `RLIMIT_CPU` 1 (`SIGXCPU` after about one second of CPU time). Workload records and created-init limits must equal runc's, with one exception: the `Max open files` line of a waiting init whose config omits `RLIMIT_NOFILE`, even when it sets other rlimits. That covers the absent lists and the `RLIMIT_FSIZE` case, and this runtime's value there is asserted as the inherited 256:512. runc's Go runtime raises its own soft `RLIMIT_NOFILE` during bootstrap and restores the inherited value at `execve` (`maybeClearRlimitNofileCache`), so a waiting runc init shows, for example, 511:512 where this runtime's shows the inherited 256:512. The workloads and every configured value are still compared exactly. Each of these must fail `run` and `create` under both runtimes and leave no state or process: an unlimited `RLIMIT_NOFILE` followed by a valid one, a lower-then-raise sequence from a caller without `CAP_SYS_RESOURCE` (the same final entry alone succeeds), `RLIMIT_NOFILE` above `fs.nr_open`, soft above hard, and an unknown name. With tiny `RLIMIT_NOFILE` 3 and `RLIMIT_AS` 1 GiB, each runtime's own remaining bootstrap runs under the limit. That is runc's descriptor and memory overhead (Go init, exec FIFO) against this runtime's (Swift init, start socket), not OCI semantics. So the script records and prints which steps succeeded under each runtime, with their errors, instead of requiring identical outcomes. Under both runtimes:
- no step may time out (statuses 124, 137, and 143 fail);
- a created init must hold the limit when `create` returns;
- a workload that ran must observe the limit exactly;
- a start that cannot be served must leave a stopped container that plain `delete` removes;
- nothing may be left behind.

Under `RLIMIT_NOFILE` 3, this runtime's `create` must fail synchronously with the start-descriptor diagnosis and leave nothing behind. A created init that dies before it can be sampled is recorded as stopped. Leftover checks match bundle command lines, and also any process whose `/proc/PID/root` is the test rootfs. For `RLIMIT_AS`, the workload reports its own `getrlimit` value. It then reserves 1536 MiB and 1 MiB of address space with real `PROT_NONE`/`MAP_NORESERVE` `mmap` calls, which touch no memory, and unmaps them. Under the 1 GiB limit the large reservation must fail with `ENOMEM`. A control without `RLIMIT_AS` must report unlimited, and there the same reservation must succeed. Foreground parent-death cleanup is checked under `RLIMIT_NOFILE` 3.

The local development environment has Apple `container` 1.5 and a cached `swift:6.4.1` image. Besides the disposable VMs used by `scripts/test-linux.sh`, it keeps a persistent `srunc-dev` machine built from [`scripts/machine/Containerfile`](../scripts/machine/Containerfile) (Ubuntu 26.04, Swift 6.4.1, the OCI fixtures and runtime-tools dependencies):

```sh
container build -t srunc-dev:6.4.1 -f scripts/machine/Containerfile scripts/machine
container machine create srunc-dev:6.4.1 --name srunc-dev --set-default
```

The home directory is mounted read-write over virtiofs, which cannot hold device nodes, so runtime-tools needs `TMPDIR` on the machine's own disk (for example `/var/tmp`). Use a separate scratch path such as `.build/machine-6.4.1`: `.build/linux-6.4.1` holds module caches built at `/workspace`. The machine has no AppArmor or SELinux, so those runtime-tools suites are host-excluded there. A successful Swift build inside an Apple container checks Linux compilation; a namespace smoke test must separately demonstrate that its guest environment grants the required kernel capabilities.

The [engine baseline](engine-baseline.md) records pinned live capture evidence and
its limits. `scripts/logging-integration.sh` also runs on macOS: its synthetic
failure probes exercise the CLI/log contract without launching a container.

`scripts/kill-integration.sh` compares runc 1.4 signal semantics, with a real
subreaper, shared/private PID namespaces, surviving descendants after init exits,
paused and stopped states, descendant cgroups, non-KILL init-only signaling and
bystander/stale-identity safety. It needs cgroup v2 `cgroup.kill` (Linux 5.14+).

`scripts/filesystems-integration.sh` mounts sysfs, mqueue, tmpfs-based shm and a
read-only tmpfs in new network/IPC namespaces. It compares run/create/start/exec
with runc, verifies mount types/flags before start, EROFS, private network and IPC
views, and a symlinked sysfs target's failure cleanup without host mount changes.
The probe is `scripts/fixtures/mount-probe.c`; its host queue is explicitly removed.

`scripts/devices-integration.sh` checks BPF device enforcement in init and exec,
read/write and mknod decisions, failed create cleanup, adopted filter ownership,
inherited restrictions, retained policy through resource updates, rejected live
device-rule patches, and fail-closed setup without BPF privileges. It uses the
existing static BusyBox/clang fixture plus util-linux `setpriv`.

The opt-in engine gate is separate from the ordinary suite inventory because it
requires an installed, running daemon and the pinned profile in
[engine baseline](engine-baseline.md):

```sh
sh scripts/containerd-integration.sh .build/linux-6.4.1/debug/srunc /tmp/sct-engine/containerd.sock
```

It selects the supplied binary explicitly, creates its own containerd namespace,
runtime root, cgroup subtree and directory rootfs, and cleans them up. It checks
pipes/EOF, init/exec PID files, exit codes, shim reaping, kill/delete, error logs
and failure cleanup. It does not change a daemon default or test Docker, image
unpacking, network provisioning, TTYs or default seccomp/LSM security.

`scripts/bind-integration.sh` checks file/directory bind and rbind through real
I/O, mount flags, execute/device permissions, read-only roots, existing in-root
links, new target files/parents, bundle-relative sources, strictatime and private
propagation. It compares ordinary cases with runc and verifies host mount tables,
FD closure, source writes only where requested, and failure cleanup. Early
source pinning and host-backed `/dev` protection are Swift-specific regressions.

The opt-in image gate expects a previously pulled/unpacked Alpine image in its
explicit namespace, with `native` snapshotter available. It never downloads an
image or changes the daemon default:

```sh
sh scripts/containerd-image-integration.sh .build/linux-6.4.1/debug/srunc /tmp/sct-engine/containerd.sock sct-image-baseline docker.io/library/alpine@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0
```

It checks image-backed readonly config and writable volume mounts, init/exec,
PID publication, nonzero exit, reaping and native-snapshot cleanup. Set
`ENGINE_CAPTURE_DIRECTORY` only when intentionally capturing the real create
JSON; inspect image-provided environment values before sharing that artifact.

`scripts/network-namespace-integration.sh` compares absolute proc and nsfs network
paths with runc using a private loopback listener. It checks create-time namespace
identity, init/exec TCP, exec after the source path disappears, descriptor closure,
caller isolation, and cleanup. Missing, ordinary-file, FIFO, wrong-type and
privilege-denied paths must fail without running the workload or leaking state.
It uses the existing static clang fixture and util-linux `unshare`/`setpriv`.

The opt-in image/network gate wraps the same image test with an externally
prepared private namespace and checks actual TCP from engine exec:

```sh
sh scripts/containerd-network-integration.sh .build/linux-6.4.1/debug/srunc /tmp/sct-engine/containerd.sock sct-image-baseline docker.io/library/alpine@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0
```

The wrapper owns and removes the listener; the image gate owns task/snapshot
cleanup. This tests supplied namespace consumption, not bridge/NAT/DNS provisioning.

Linux builds require `libseccomp-dev` in addition to the existing Swift toolchain
and fixture packages; CI and `test-linux.sh` install it. The checked guest uses
libseccomp 2.6.0. Static or musl distribution remains a separate validation gate.

`scripts/seccomp-integration.sh` compares init/create/start/exec as root and uid
1000 with no_new_privs true/false, persisted policy after bundle edits/removal,
all argument operators, 64-bit arguments, distinct-index AND and repeated-index
OR, errno/trace/log/termination actions, explicit flags and cleanup against runc.
An inherited filter refusing new seccomp loads proves fail-closed handling.
Malformed/unsupported policies and unknown nonredundant syscall names must fail
without state, cgroups or a workload. The direct syscall helper is
`scripts/fixtures/seccomp-probe.c`.

The opt-in image/security gate runs containerd's own default profile and an
explicit getcwd/EACCES profile, verifies init filter mode and exec enforcement,
and retains the existing image/lifecycle/cleanup checks:

```sh
sh scripts/containerd-seccomp-integration.sh .build/linux-6.4.1/debug/srunc /tmp/sct-engine/containerd.sock sct-image-baseline docker.io/library/alpine@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0
```

`containerd-seccomp-capture.sh SOCKET NAMESPACE IMAGE@sha256:DIGEST NEW_OUTPUT_DIR`
records the matching reference runc profiles and direct syscall results. It never
uses Swift as the reference. Captured JSON can include image environment values;
inspect them before sharing. Both scripts use the existing daemon and cached image.

`scripts/oom-integration.sh` compares -1000...1000 values (including endpoints),
absent/null and explicit zero, nonzero inherited scores, root/non-root init and
exec, create-time procfs values, bundle edits/removal and ignored process-file
OOM overrides with runc. Dropping only CAP_SYS_RESOURCE verifies negative-write
failure before namespace setup. Range failures, state/cgroup cleanup and unchanged
caller/init scores are required. This changes OOM selection preference; it does
not deliberately trigger an OOM kill or alter the memory-event tests.

`scripts/lsm-integration.sh` reports which modules the host enables and covers
what it can: empty labels, refused unavailable AppArmor/SELinux labels for run,
create and exec, a refused nonempty `linux.mountLabel`, and cleanup. Confinement
itself needs an AppArmor host: `sudo sh scripts/apparmor-integration.sh BINARY`
loads two throwaway profiles and compares init/exec confinement with runc. The
Apple `container` guest has neither module enabled; a Lima Ubuntu 26.04 VM does.
Its glibc matches the `swift:6.4.1` image, so a binary built there with
`--static-swift-stdlib` runs with only libseccomp2 installed.

`scripts/keyring-integration.sh` compares named session identity, caller-key
exclusion, root/non-root init/exec, shared session keys, distinct live container
IDs, foreground/detached/create/start, persistent `--no-new-keyring`, bundle
removal and cleanup with runc. Its direct keyctl helper needs only Linux headers
and the existing static clang fixture, with no libkeyutils dependency. Swift-only
checks inject EPERM/ENOSYS for joins and permission changes, keep init alive after
a failed exec, preserve legacy records' inherited sessions, and verify the explicit
opt-out skips unavailable setup. Keyring-unavailable hosts fail rather than skip.

The opt-in image identity gate binds the same diagnostic probe into Alpine:

```sh
sh scripts/containerd-keyring-integration.sh .build/linux-6.4.1/debug/srunc /tmp/sct-engine/containerd.sock sct-image-baseline docker.io/library/alpine@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0
```

Init writes its session ID through the volume, then two engine execs add/read a
key in that same session. This explicit diagnostic profile permits keyctl and has
no seccomp profile. Separately, the existing default/custom seccomp image gate
verifies keyring setup occurs before workload filtering; it does not weaken the
engine's default seccomp rules to allow the diagnostic syscalls.

## OCI runtime-tools validation

CI also runs the unmodified `opencontainers/runtime-tools` validation executables
at the commit in [`scripts/runtime-tools-revision`](../scripts/runtime-tools-revision).
This is an independent OCI gate, separate from the project's differential tests.
The declared host is rootful Linux with cgroup v2 and a private mount namespace.

On a disposable Linux host, install Go, make, Perl (`prove`), Python 3, git,
`busybox-static`, and `libseccomp-dev`, then run from the repository root:

```sh
swift build --product srunc
sh scripts/prepare-runtime-tools.sh .build/runtime-tools-upstream
sudo python3 scripts/runtime-tools-integration.py \
  .build/debug/srunc .build/runtime-tools-upstream .build/runtime-tools-results
```

The runner uses a separate state root, applies a per-executable timeout, checks
both exit status and TAP plans/assertions, and cleans up only its own containers.
`tap-go` embeds JSON in TAP diagnostic blocks, which Perl's YAMLish reader rejects;
the parser receives a copy with only those blocks removed, while raw output is
retained. Generated rootfs/probe fixtures live in `.srunc-fixture/` inside the
upstream checkout, so tracked upstream tarballs and source remain unchanged.
Upstream bundles are created under the runner's private temporary directory.
The masked and read-only path suites create a character device 0:0 there, which
overlayfs rejects as a whiteout, so the runner refuses to start unless `TMPDIR`
is on a filesystem that permits it; CI uses the workspace bind mount instead of
the job container's overlay `/tmp`. Two upstream negative executables have no TAP: their exit status and
specific invalid-capability/rlimit rejection diagnostics are required instead.
The rootfs tarball includes the static probe and has mode 0755 so mapped and
non-root users can execute it.

This is **not a claim that every upstream executable passes**. The versioned
[`runtime-tools-exclusions.json`](../scripts/runtime-tools-exclusions.json) names
16 cgroup-v1-only executables and six upstream defects or invalid inputs, with
individual reasons. On 2026-10-19 all six were rerun by name on Ubuntu 26.04.1
arm64 (the `srunc-dev` container machine below) against Ubuntu's runc
1.4.0-0ubuntu1 and upstream runc v1.5.2 (static release binary, checksum
verified, Go 1.26.8, libseccomp 2.6.1); both runcs and srunc fail every one.
runc 1.4.0 reproduces each documented defect: prestart hook state, FIFO device
numbers, filesystem data on bind mounts, killing an exited pidfile workload, Go
startup under its requested rlimits, and the unset-process start test. runc
v1.5.2 shows the same causes for the device, bind-mount, rlimit and start tests
and still reports `creating` to prestart hooks. Its `hooks_stdin` and `pidfile`
runs fail earlier: the suite's default seccomp allowlist predates `faccessat2`,
which v1.5.2's created init calls, so the init exits before `start` (allowing
only that syscall keeps it `created`). The pidfile defect is tracked in
[upstream issue 805](https://github.com/opencontainers/runtime-tools/issues/805). Existing static C-probe and lifecycle integrations
remain the gates for these behaviors; runtime validation is not weakened.
SELinux and AppArmor tests are excluded only when their required host policy is
unavailable. CI loads the upstream AppArmor profile on an AppArmor-enabled host.

Every exclusion appears in the job summary and `results.json`, alongside raw TAP,
normalized TAP and parser logs for executed tests. An unexpected failure,
nonzero exit, timeout, malformed/truncated TAP, failed cleanup or zero passing
executables fails the gate. To audit everything without exclusions, add `--strict`.
Naming individual suites also bypasses exclusions:

```sh
sudo python3 scripts/runtime-tools-integration.py \
  .build/debug/srunc .build/runtime-tools-upstream .build/runtime-tools-strict --strict
sudo python3 scripts/runtime-tools-integration.py \
  .build/debug/srunc .build/runtime-tools-upstream .build/runtime-tools-namespaces \
  linux_ns_itype linux_ns_path linux_ns_nopath linux_uid_mappings
```

### Current runtime-tools status

Recorded 2026-10-19 at upstream `bd3b0bd` (58 executables). Both hosts use
cgroup v2 and Ubuntu 26.04.

| Host | Passed | Excluded | Failed | Host exclusions |
| --- | --- | --- | --- | --- |
| Hosted CI, x86_64 `ubuntu-26.04` runner, privileged `swift:6.4.1` container | 35 | 23 | 0 | SELinux |
| `srunc-dev` container machine, arm64, kernel 6.12.28 | 34 | 24 | 0 | SELinux, AppArmor |

How far each exclusion group is justified:

- **cgroup v1 (16):** a scope decision, not an upstream defect. The suites read
  v1 controller paths and srunc supports only cgroup v2. They were classified
  from source and have not been run on 26.04; the cgroup v2 integration suites
  above cover these controllers instead.
- **Upstream defects (6):** each reason explains why the test is wrong, and all
  six were rerun by name on arm64 against runc 1.4.0-0ubuntu1, upstream runc
  v1.5.2 and srunc; every runtime fails every one. runc v1.5.2 stops
  `hooks_stdin` and `pidfile` earlier on the suite's missing `faccessat2`
  seccomp rule, so on v1.5.2 the `pidfile` defect itself is masked; runc 1.4.0
  reproduces it. The rerun was not repeated on x86_64.
- **Host LSM (1–2):** applied only when the policy is missing. AppArmor runs
  and passes in CI. SELinux is unavailable on both hosts, so `linux_mount_label`
  has not run against srunc anywhere.

Open follow-ups, cheapest first: run the cgroup v1 suites on `srunc-dev` to
confirm they fail only on v1 paths; rerun `pidfile` and `hooks_stdin` against
runc v1.5.2 with a copied config that adds `faccessat2`; repeat the six-test
rerun on x86_64; and find an SELinux-enforcing host for `linux_mount_label`.
