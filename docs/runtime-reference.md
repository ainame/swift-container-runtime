# Runtime reference

Detailed command behavior, supported configuration, and launch design.
For an introduction, see the [README](../README.md). Run commands from the repository root.

## Run an OCI bundle

```sh
swift build
sudo .build/debug/swift-container-runtime run --bundle /path/to/bundle mybox
```

Requires root and Linux 5.11 or later: `close_range` with `CLOSE_RANGE_CLOEXEC` (5.11; plain `close_range` is 5.9). `namespace-run` still needs only 5.3. `--bundle` (`-b`) defaults to the current directory, like runc. The runtime reads `config.json`, sets up the container, waits for the workload, and exits with its status. While it runs, the container is visible to `state`, `kill`, and `delete --force`; its state is removed when the workload exits or setup fails, as with runc. `run --keep` retains stopped state and its cgroup until `delete`. `create` and `run` accept `--pid-file PATH`, which atomically replaces PATH with the decimal host init PID (without a newline); relative paths use the caller’s working directory. The PID file remains after exit and deletion. Publication failures fail the launch and clean it up. Setup failures exit 125 and print the failing step. Usage errors exit 64.

## Container lifecycle

```sh
rt="sudo .build/debug/swift-container-runtime"
$rt create --bundle /path/to/bundle mybox < /dev/null > mybox.log 2>&1
$rt state mybox          # status "created"; the workload has not run
$rt start mybox          # returns once the workload's execve succeeded
$rt pause mybox          # freezes every task; state reports "paused"
$rt resume mybox         # thaws the container
$rt list                 # ID PID STATUS BUNDLE CREATED OWNER
$rt kill mybox TERM      # default TERM; names (KILL, SIGKILL) or numbers
$rt delete mybox         # stopped (or created) containers; --force kills a running one
$rt run --detach --bundle /path/to/bundle other   # create + start, then return
```

The semantics follow runc:

- **State root.** `--root PATH` (before or after the subcommand) selects the state directory; the default is `/run/swift-container-runtime`. It is created with mode 0700 and must belong to the caller and not be group- or world-writable. Each container uses `<root>/<id>/`, opened relative to the root without following symlinks. On macOS the commands compile and run the same code, but every Linux-only system call fails with `ENOSYS`, so no container state is ever created there.
- **Status.** `state` prints OCI state JSON (`ociVersion`, `id`, `pid`, `status`, `bundle`, `rootfs`, `created`, and `annotations` when present), pretty-printed with sorted keys. The status is `creating`, `created`, `running`, or `stopped`, and is derived on every query from the live system rather than stored: the init counts as running only while its PID still has the recorded `/proc/<pid>/stat` start time and boot ID and is not a zombie. `pid` is 0 when stopped. `list` prints runc's table, `--format json` a JSON array (`null` when empty, as in runc), and `--quiet` only IDs; unreadable entries are reported on stderr and skipped.
- **Transitions.** `start` needs `created` and succeeds at most once, also under concurrent starts. `kill` normally needs `created`, `running` or `paused`. `kill --all` also succeeds for stopped containers; SIGKILL kills the recorded cgroup subtree when the PID namespace is shared, including surviving children after init exits. Other signals target init only. `delete` removes a `stopped` container and, like runc, also a `created` one after killing its waiting init; a `running` one needs `--force`, which sends SIGKILL, waits up to 10 seconds, and then removes the state. `delete --force` of a missing container succeeds. Invalid transitions fail with `cannot <command> container <id> in the <status> state`. Duplicate IDs fail with `container <id> already exists`.
- **Bundles.** The bundle and rootfs are stored as canonical absolute paths. Everything later commands need is in `state.json`, so the bundle may be renamed or removed after `create`.
- **Stdio.** The workload inherits the stdin, stdout, and stderr of `create` or `run --detach`, which the waiting init holds open. Redirect them when capturing that command's output; otherwise a capture such as `$(... create ...)` waits for the container to exit, as with runc.
- **Exit statuses.** Lifecycle command failures exit 1, as in runc; `run` failures exit 125.

### Lifecycle design

`exec` runs another nonterminal process in a created or running container:

```sh
$rt exec mybox /bin/echo hello
$rt exec --cwd /tmp -e GREETING=hello --user 1000:1000 mybox /bin/sh -c 'echo "$GREETING"; id'
$rt exec --detach --pid-file worker.pid mybox /bin/sleep 60
$rt exec --process process.json mybox
```

Place runtime options before the container ID; all arguments after the ID are passed to the workload. The command-based form rereads process defaults from the bundle, as runc does, so that bundle must still exist. `--process` (`-p`) instead loads a standalone OCI process object; it works after bundle removal and takes precedence over command arguments and process CLI overrides. Exec joins the live init's pinned namespaces and root and the recorded cgroup, confirms execution, and returns the workload status (or zero with `--detach`). Failure cleans up its own process and leaves init alone. It refuses paused or stopped containers. `--additional-gids` (`-g`, numeric, repeatable) appends to the configured supplementary groups as runc does, validated with them (below 4294967295, at most 65536 in total); absent, the configured groups are kept. `--no-new-privs` sets `no_new_privs`; absent, `process.noNewPrivileges` is kept. runc also accepts `--no-new-privs=false` to clear a configured setting; that explicit-false form is not supported here and is rejected. A paused container refuses exec unless `--ignore-paused` is given; then exec waits, without holding the state lock, until the same init and cgroup are resumed, and fails if the container is killed, deleted, or recreated meanwhile. Unlike runc, which forks the process into the frozen cgroup, nothing is forked before resume. `--cap` (`-c`, repeatable, exact names such as `CAP_KILL`) appends to the bounding, effective, and permitted sets as runc does, never to inheritable; when the configured process has an inheritable set (even empty), a requested capability that is in it is also appended to ambient, which matches what runc ends with after warning that raising the others failed. Without `process.capabilities` the request starts from an empty object (runc would dereference nil), so the exec process holds only the requested capabilities rather than the inherited ones. Unknown names are rejected rather than ignored, and `--process` ignores `--cap`. Terminals, signal forwarding, sub-cgroups, socket activation (`LISTEN_FDS`), and console socket handoff remain to be added.

`run`, `create`, and `exec` accept `--preserve-fds N` (before the container ID), as runc does: caller descriptors 3 through 2+N reach the workload at the same numbers, and everything from 3+N up is marked close-on-exec. The runtime never closes, renumbers, or chowns them, and does not check their type. For `create`, the waiting init holds them until `start`. Each one must be open and not close-on-exec. This is checked once before any state, lock, or plan descriptor exists, so a missing descriptor cannot be silently filled by one of the runtime's own, and again just before the fork. Every runtime descriptor is close-on-exec, so this proves that none of them sit in the range. This is stricter than runc, which accepts any open descriptor, so its own handle can fill a hole. Negative counts are rejected, where runc ignores them. A count whose first unpreserved descriptor, 3+N, would exceed the 32-bit descriptor range is also an error. The shared setup applies configured limits, credentials, and capabilities; the detailed exec security matrix remains future validation.

`--pidfd-socket PATH` (on `create`, `run`, and `exec`) connects to a host AF_UNIX stream socket before forking; the new process opens its own pidfd and sends it with one `SCM_RIGHTS` message labelled `standard` (container init, after rootfs and hostname setup, before `no_new_privs` and credentials) or `setns` (exec, before `no_new_privs`), as runc does.

A leading `@` names an abstract socket and the Go `DialUnix` length limits apply. As in runc, a relative path resolves in the bundle for `run`, `create`, and command-form `exec`, and in the caller's working directory for `exec --process`; the runtime never changes its own working directory and connects through an O_PATH handle instead. The socket is dialled only after the container ID, state, and plan are accepted, just before the fork, so a refused ID never connects. A failed connect or send fails the launch and cleans up. In the foreground, the launcher holds its copy of the connection until the workload exits, so the listener sees EOF only then. Deliberate differences: an empty value is rejected (runc ignores it), and a kernel without `pidfd_open` fails in the child rather than in a pre-check.

There is no monitor process. `create` forks the usual launcher and init. The launcher reports the init's PID while it is still an unreaped child, the CLI pins it with a pidfd, records its start time and boot ID, and only then releases the launcher, which stays the init's parent until the CLI's verdict. The init completes the whole setup (namespaces, mounts, `pivot_root`, hostname, cwd, umask, `no_new_privs`, `process.rlimits`, the configured user and groups, and the `process.args[0]` lookup, which must find a file executable by that user), reports readiness, and waits with those credentials already in force. The CLI writes `state.json` and sends a commit byte; if the CLI fails or dies before that, the init sees EOF and exits, and the failed create kills it through the pidfd and removes the state directory. A detached init has no parent-death signal and starts a new session.

Detached processes follow runc's reaping contract. After a successful detached `create`, `run`, or `exec`, the launcher exits and the process is reparented to the caller's nearest subreaper, or else to PID 1 of the caller's PID namespace; reaping it is the caller's job (runc `docs/terminals.md`: the parent of a detached process should be a subreaper). A PID 1 that never reaps, such as `tail -f /dev/null` in a surrounding Docker container, leaves exited processes as zombies, and a zombie exec process keeps its container's PID namespace from tearing down, so the container never reads as stopped. A failure detected within the launch handshake (setup, a failed `execve`, or exec's PID-file publication) kills the child through its pidfd, and the launcher reaps it before exiting, as runc reaps a process it terminates. No runtime process stays behind to monitor a successful launch. Limitation: `create` and `run --detach` publish `--pid-file` after the launcher has exited, so an init killed for that later failure is still left to the caller's reaper.

The created init listens on `start.sock` in the state directory (bound by the CLI before forking). Its presence marks the container created. Because the init already runs as the workload user, it cannot modify the private, root-owned state directory, so `start` consumes the marker on the host while holding the container lock:

1. `start` connects and sends a request.
2. The init ignores a client that has already hung up; otherwise it replies `accepted`.
3. `start` checks that `start.sock` is still the socket it connected through, unlinks it (the commit point: the container now reads as running), and sends a commit.
4. The init reads the marker's link count through an O_PATH handle on the socket inode, which it inherited (it holds no directory handle). If the marker is still linked, the start never happened and it serves the next client. If it was unlinked and the commit arrived, it closes its gate descriptors and calls `execve`. If it was unlinked but the client died before committing, it exits without running anything, so the container reads as stopped.

A `start` that dies before step 3 therefore leaves the container created and startable. The init waits for the commit without a deadline: a timeout could race with the unlink and leave a running status with no workload. The connection is close-on-exec: `start` sees EOF after a successful exec, or the exec error, which it reports. Unlike runc's exec FIFO, `start` therefore confirms the exec itself; an init killed from outside between the commit and `execve` is not distinguished from a quick exit.

Signals and deletion go through `pidfd_send_signal` on a pidfd that is verified after it is opened: the PID must still have the recorded start time and boot ID, must not be PID 1 or the caller, and for a container with a PID namespace must be outside the caller's PID namespace. A reused PID or tampered state therefore cannot direct a signal to an unrelated process; such a container reads as stopped.

Mutating commands (`create`, `start`, `kill`, `delete`, `run`) take an exclusive `flock` on the container directory for one short synchronous critical section, with waits bounded to 30 seconds. `state` and `list` take no lock; `state.json` is replaced atomically by writing and syncing a temporary file and renaming it. Forked children close their copy of the lock descriptor first, so a long-lived init never holds it. `mkdirat` makes duplicate creates fail atomically.

Without a PID namespace, killing the init does not kill other workload processes. `delete` and `delete --force` do: they kill everything left in the container's cgroup through `cgroup.kill`, but only after checking the recorded boot ID and inode.

## Example bundle

A minimal `config.json` for a static BusyBox rootfs:

```json
{
  "ociVersion": "1.0.2",
  "root": {"path": "rootfs"},
  "process": {
    "terminal": false,
    "user": {"uid": 0, "gid": 0},
    "args": ["/bin/sh", "-c", "echo hello from $(hostname)"],
    "env": ["PATH=/bin"],
    "cwd": "/"
  },
  "hostname": "swiftbox",
  "mounts": [
    {"destination": "/proc", "type": "proc", "source": "proc", "options": ["nosuid", "noexec", "nodev"]},
    {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]},
    {"destination": "/dev/pts", "type": "devpts", "source": "devpts", "options": ["nosuid", "noexec", "newinstance", "ptmxmode=0666", "mode=0620", "gid=5"]}
  ],
  "linux": {"namespaces": [{"type": "pid"}, {"type": "mount"}, {"type": "uts"}, {"type": "ipc"}]}
}
```

`runc spec` output does not run unchanged, because it asks for a terminal and more. This runtime rejects those fields instead of ignoring them.

### Supported subset

| Field | Supported |
| --- | --- |
| `ociVersion` | `1.x` |
| `root.path` | Relative to the bundle or absolute, non-empty, without NUL; resolved to a canonical directory other than `/`. Bundle and rootfs paths must be valid UTF-8. `root.readonly` `true` makes the container's root mount read-only after setup; absent or `false` leaves it writable. |
| `process.args` | `args[0]` must be non-empty. As runc does with Go's `exec.LookPath`, after the cwd change and credential switch: a name containing `/` is used as given (absolute, or relative to the cwd); any other name is searched in the process's own `PATH` (the last `PATH` entry in `process.env`, never the caller's), with empty elements meaning `.` and each candidate lexically cleaned. The first existing, non-directory candidate executable by the workload credentials wins; one found through a relative or empty element is refused (Go's `ErrDot`), and a failed search reports "executable file not found". A missing or empty `PATH` finds nothing. `argv[0]` is passed unchanged; only the `execve` file is the resolved path. Exec `-e PATH=...` overrides the bundle `PATH` for the lookup. Unlike Go, executability is checked with `access(X_OK)` without its mode-bit fallback on `EPERM`/`ENOSYS`. |
| `process.env` | `NAME=value` entries without NUL; all are validated, then, as in runc, the last occurrence of a name wins (kept in the order of those last occurrences). This is the **entire** environment: nothing is inherited from the caller and, unlike runc, no `HOME` is added. |
| `process.cwd` | Absolute, without `.`/`..`; created if missing (as in runc). |
| Container paths | `process.cwd` and mount destinations are limited to 128 components and 4095 bytes. |
| `process.user` | `uid`, `gid`, `additionalGids`, `umask` (absent: uid/gid 0). IDs must be below 4294967295, at most 65536 groups, `umask` at most `0777` (default `0022` as in runc, not the caller's mask). Supplementary groups are always replaced, so an absent or empty list clears the caller's. `username` is rejected. |
| `process.noNewPrivileges` | Sets `PR_SET_NO_NEW_PRIVS` before the user switch. |
| `process.capabilities` | `bounding`, `effective`, `inheritable`, `permitted`, `ambient`, with exact names such as `CAP_CHOWN`. As in runc, an absent (or `null`) object leaves the inherited sets alone; a present object replaces all five, and an absent member is empty, so `{}` drops every capability, the bounding set and inherited ambient capabilities included. Unknown names, names above the kernel's `cap_last_cap`, and ambient outside permitted ∩ inheritable are rejected before launch, where runc warns and ignores them; effective outside permitted is rejected before launch too (runc fails at `capset`). As in runc, permitted may exceed bounding (`execve` drops the excess) and inheritable may exceed bounding when the caller already has those bits inheritable; whatever the kernel's `capset` refuses (for example a permitted capability the runtime lacks) fails setup with that requirement in the error. |
| `process.rlimits` | `type`, `soft`, `hard` for the sixteen Linux names runc accepts (`RLIMIT_CPU` … `RLIMIT_RTTIME`). Values are 64-bit, and `18446744073709551615` means unlimited. An absent, `null`, or empty list keeps the caller's limits. As in runc, every entry is applied in input order with one `prlimit64` per entry, repeats included, so an earlier entry the kernel refuses fails setup even if a later one of the same type would be grantable. Unknown names and soft above hard are rejected before launch (runc fails at its `prlimit`). A missing `soft` or `hard` is rejected; Go's decoding in runc treats it as 0. Kernel refusals fail `create` or `run` with the entry's index, for example a raised hard limit without `CAP_SYS_RESOURCE`, or `RLIMIT_NOFILE` above `fs.nr_open`. |
| `process.terminal` | Absent or `false`; stdio is inherited directly. |
| `hostname` | Requires a `uts` namespace. |
| `linux.namespaces` | New `mount` (required), `pid`, `uts`, `ipc`, `network` namespaces. No `path` joins. The network namespace is left unconfigured; even loopback is down. |
| `linux.rootfsPropagation` | Absent, `private`, or `rprivate`; propagation is always made `rprivate`. |
| `linux.readonlyPaths`, `linux.maskedPaths` | Absolute paths without `.`/`..` or NUL; `/` is accepted. Read-only repeats are applied again, as in runc; a masked repeat is applied once. No `/proc` mount is needed. Missing paths are skipped; symlinks are followed only within the container root, and magic links are refused. Read-only paths need Linux 5.12+. See setup step 7. |
| `linux.cgroupsPath` | cgroup v2 only, mounted at `/sys/fs/cgroup`. Absent or empty: `/swift-container-runtime/<id>`; relative: below `/swift-container-runtime`; absolute: below the cgroup root. `.`/`..` components, NUL, newlines, the root itself, components over 255 bytes, more than 64 components, and more than 4095 bytes are rejected. Every container gets a cgroup, and the init joins it while blocked, before `create` returns and before the workload executes. Missing ancestors are created and left in place at delete. Controllers needed by the configured resources are enabled in each ancestor's `cgroup.subtree_control`, and failing to enable one fails setup. A "domain invalid" cgroup is made threaded when no domain controller (memory or configured CPU, as runc classifies it) is needed, and is an error when one is. A supplied, pre-existing cgroup must have no processes, no child cgroups, and must not be frozen. It is used and kept at delete; a cgroup this runtime created is removed. Containers given the same path are separate processes, possibly with different state roots. Each takes a nonblocking exclusive `flock` on the leaf directory, through a close-on-exec descriptor. Under the lock it rechecks that the path still names the opened directory and that the group is unused, writes the limits, and joins the init. It releases the lock as soon as the init is a member, or when setup fails. A contender fails with "is being set up by another container", or afterwards with "is not empty", without writing anything. The cgroup's path, inode, and boot ID are recorded in the state. At delete, a cgroup recorded under another boot, or replaced at the same path (another inode), is left untouched with a warning. Remaining processes are killed through `cgroup.kill` (Linux 5.14+) only when the cgroup is still the recorded one. Foreground `run`, failed setup, `delete`, and `delete --force` clean up the cgroup. |
| `linux.resources` | Device access rules (below), plus `memory.limit`, `memory.reservation`, `memory.swap` (memory+swap, as in runc), `memory.checkBeforeUpdate`, `pids.limit`, and `cpu.shares`, `cpu.quota`, `cpu.period`, `cpu.burst`, `cpu.idle`, `cpu.cpus`, `cpu.mems`, converted and written as runc's fs2 driver does: `pids.max`, `memory.swap.max`, `memory.max`, `memory.low`, then `cpu.idle`, `cpu.weight`, `cpu.max.burst`, `cpu.max`, `cpuset.cpus`, `cpuset.mems`. CPU: shares become `cpu.weight` by runc's quadratic conversion (0 writes nothing, 1024 is 100, clamped to 1..10000); a nonzero quota or period becomes `cpu.max` (a quota that is not positive is `max`, and a zero period is 100000); a burst the current quota refuses is retried after `cpu.max` only when the quota is nonzero; idle and burst 0 are real writes. Ranges are left to the kernel, whose refusal fails setup, so an idle group refuses shares. CPU counts as a domain controller, as in runc, so a threaded subtree is refused. Cpusets: nonempty CPU/node lists are passed to the kernel; absent or empty lists leave existing configured values unchanged, and effective sets inherit from the parent when unset. Memory: -1 is `max` and 0 is unset; below -1 is rejected. A swap without a memory limit, or a memory+swap below the memory limit, is rejected. A swap of `max` or 0 is skipped when `memory.swap.max` is missing, and swap -1 alone does not require the memory controller. pids: any negative is `max`, and 0 becomes 1, as in current runc. Every other resource (`cpu.realtimeRuntime`, `cpu.realtimePeriod`, `blockIO`, `hugepageLimits`, `network`, `rdma`, `unified`, and the other `memory` fields such as `swappiness`, `kernel`, `disableOOMKiller`, `checkBeforeUpdate`) is rejected. When setup or start fails and `memory.events` shows a new `oom_kill` since setup began, the error says the init was OOM-killed, as runc's does. |
| `mounts` | `proc` at `/proc` (requires a `pid` namespace), `tmpfs`, `sysfs` and `mqueue` at directory destinations, `devpts` at `/dev/pts`. Flags: `nosuid`/`suid`, `nodev`/`dev`, `noexec`/`exec`, `strictatime`, `ro`, `rw` (the last `ro`/`rw` wins). A tmpfs at `/dev/shm` supplies shared memory; mqueue uses the current IPC namespace and a fresh sysfs mount reflects the current network namespace. Data: tmpfs `mode=`/`size=`; devpts `newinstance`, `ptmxmode=`, `mode=`, `gid=`. |
| `/dev` | With a tmpfs at `/dev`, creates `null`, `zero`, `full`, `random`, `urandom`, `tty` (via `mknod`) and the `fd`, `stdin`, `stdout`, `stderr` links, plus `ptmx` when devpts is mounted. Without a `/dev` tmpfs, `/dev` is left as the rootfs provides it. |
| `annotations` | Accepted and ignored. They do not affect behavior. |

Every other field is rejected with its JSON path, for example `config.json: unsupported field(s): process.oomScoreAdj`. This includes hooks, `oomScoreAdj`, `apparmorProfile`, seccomp, resources outside the memory/pids/CPU/device subset above, custom device entries, sysctl, user/cgroup/time namespaces, ID mappings, other filesystem types and broader propagation options.

### Setup sequence

Validation builds an immutable plan before any process is created. The launch then follows these steps:

1. Fork a launcher. It unshares the requested namespaces and makes `/` `rprivate`, so later mounts stay in the new namespace.
2. Fork the namespace init (PID 1 with a `pid` namespace). It immediately marks every descriptor from 3 upward (from 3+N with `--preserve-fds N`) close-on-exec with `close_range(CLOSE_RANGE_CLOEXEC)`, so unpreserved descriptors inherited from the caller (such as a directory outside the rootfs) never reach the workload. Marking rather than closing keeps the setup-error pipe usable until `execve`. Unsupported kernels fail setup. Only stdin, stdout, stderr, and any `--preserve-fds` descriptors are passed through.
3. In the init, pin bind sources before configured mounts can hide their original paths. Open the canonical rootfs with `O_PATH|O_NOFOLLOW`, bind-mount that descriptor onto the rootfs path, reopen the path with `O_NOFOLLOW`, and require the same device and inode.
4. Apply configured mounts in their listed order. For filesystem mounts, resolve each destination from that descriptor one component at a time with `openat(O_PATH|O_DIRECTORY|O_NOFOLLOW)`, creating missing directories with `mkdirat`. A symlink component fails setup, whether it is absolute or relative and whether it points inside or outside the rootfs. Runc instead resolves such links within the rootfs. The mount itself targets `/proc/self/fd/N`, so no path is re-walked between check and use. `proc` is mounted from inside the new PID namespace. For binds, resolve targets with `openat2(RESOLVE_IN_ROOT|RESOLVE_NO_MAGICLINKS)` and create missing files or directories through pinned parents. Clone the pinned source with `open_tree`, set requested attributes on the detached clone, then attach it with `move_mount` onto the target FD. Existing target links resolve inside the root; dangling links fail.
5. Populate `/dev` only when its final configured mount is tmpfs, never after a bind replaces it.
6. Call `pivot_root(".", ".")` as runc does. Then `fchdir` to the old root, detach it with `umount2(MNT_DETACH)`, and close both root descriptors.
7. Set the hostname and create the cwd. With `root.readonly`, remount `/` (the private rootfs bind, after the cwd exists) with `MS_BIND|MS_REMOUNT|MS_RDONLY` as runc's finalizeRootfs does. The remount is not recursive, so `/proc`, `/dev`, and other tmpfs mounts keep their own flags, and the host's mount of the rootfs is untouched. It restates the `nosuid`/`nodev`/`noexec`/`nosymfollow` flags `statvfs("/")` reports, and omits atime flags so the kernel keeps them; runc first tries `MS_RDONLY` alone, which can clear flags inherited from the host mount. Then apply `linux.readonlyPaths` and `linux.maskedPaths` (below). Enter the cwd afterwards, retrying after the credential switch if the caller is denied it, as runc does.

   Path controls follow runc's readonlyPath and maskPaths, in that order, after the read-only root and before umask, `no_new_privs`, rlimits, capabilities, credentials, and the cwd change. Paths must be absolute, without `.`/`..` components or NUL. Read-only paths keep their order and repeats; a masked path repeated with the same spelling is applied once (symlink aliases are not merged, as in runc). Each path is opened with `openat2(RESOLVE_IN_ROOT|RESOLVE_NO_MAGICLINKS)` from the container root, so symlinks are followed as runc follows them inside the container, but `..` and absolute targets stay in the root, and magic links such as `/dev/stdout` fail with `ELOOP`. Mounts use the descriptor-based mount API (`open_tree`, `move_mount`, `fsopen`/`fsmount`, `mount_setattr`) on those descriptors, so no path string is walked again and no `/proc` mount is needed. A missing path (also one below an already masked directory) is skipped; any other error fails setup. A read-only path is bound recursively onto itself; the path is then resolved again and the mount it reaches gets only the read-only attribute, as runc's string remount does, so its `nosuid`/`nodev`/`noexec`/`nosymfollow` and atime flags and the mounts below it are unchanged. Which mount a lookup of `/` reaches is the kernel's decision, applied identically to runc. A masked non-directory gets the container's `/dev/null` bound over it, after checking it is the 1:3 character device. The first masked directory gets an empty read-only `nr_blocks=1,nr_inodes=1` tmpfs (retried with `nr_inodes=2`), whose mount descriptor is bound onto later masked directories, falling back to one tmpfs each if that bind fails. Each mask is then checked to be what its path shows; a mask the container cannot see (such as one stacked on `/`) fails setup instead of being reported as applied. Only the init uses its new mount namespace during setup, so no other process can add mounts between these steps; a host process able to rename entries in the rootfs could still redirect a later lookup to another file inside the container root, which the identity checks detect only for a replaced target. The rootfs is assumed to have a single owner during setup.
8. In runc's order (its finalizeNamespace): set the umask, then `no_new_privs` if requested. Then set every `process.rlimits` entry exactly, in order. runc's parent does this with `prlimit` when the init reports procReady, before credentials and capabilities change; here the init does it itself with the caller's privileges. From this step on, the rest of setup, a created init's wait, and the start handshake run under the limits, as in runc. So `RLIMIT_NPROC` is in force at `setuid`, `create` returns an init that already holds the limits, and a tiny `RLIMIT_NOFILE` or `RLIMIT_AS` can make the runtime's own remaining setup or start fail, as it can in runc. With `process.capabilities`, drop every capability outside `bounding` from the bounding set over the kernel's whole `cap_last_cap` range (this needs `CAP_SETPCAP`, still held here) and set `PR_SET_KEEPCAPS`. Then chown inherited stdio (other than `/dev/null`) to the workload uid as runc does, then `setgroups` (always, so an empty list clears), `setgid`, and `setuid`.
9. With `process.capabilities`, clear `PR_SET_KEEPCAPS`, install effective, permitted, and inheritable with `capset`, clear the ambient set, and raise each configured ambient capability. Without it nothing is changed: a non-root uid loses its permitted, effective, and ambient sets at `setuid` while keeping the caller's bounding and inheritable sets, and root keeps all of the caller's sets.
10. In the foreground, rearm the parent-death signal that the credential change cleared, then recheck the launcher through its pidfd. A detached init has neither.
11. Look up the executable with the workload credentials, as runc's create-time lookup does: missing, directory, and not-executable programs fail `create` or `run`. Then call `execve` with the configured environment. For `create`, first check that the init can accept a start connection under its final `RLIMIT_NOFILE`: it duplicates the listener into the lowest free descriptor and closes it again, since `accept4` needs that slot and fails at once without it. If there is no free slot, `create` fails. Otherwise the init reports readiness and serves the start gate. One slot suffices, because the init opens nothing else before serving and closes each connection before the next `accept`.

The runtime forwards the workload's exit status (or 128+signal). A setup failure after namespace creation needs no explicit unwinding: the mounts exist only in the dying mount namespace.

Like runc, the runtime creates missing mount-target and cwd directories inside the rootfs, so it can modify the bundle's rootfs.

The bundle and rootfs are trusted input. They must not be changed by other host processes between loading `config.json` and `pivot_root`. The rootfs identity check in step 3 detects a replaced final directory but does not make setup race-free: path-based steps such as `realpath` and the bind target can still be redirected by a concurrent change to a parent directory.

## Try the namespace lab

Requires Swift 6.4 (Linux validation uses Swift 6.4.1) and Linux with permission to create namespaces and mount procfs, normally root with the necessary capabilities. The launcher currently requires Linux 5.3 or later for pidfds.

```sh
swift build
sudo .build/debug/swift-container-runtime namespace-run --hostname swiftbox -- /bin/sh -c 'hostname; echo $$'
```

The executable after `--` must be an absolute path. Expected output:

```text
swiftbox
1
```

The command runs as PID 1, so normal Linux PID 1 signal behavior applies. The runtime waits for it and forwards its exit status. For ordinary workloads retaining their parent-death signal setting, terminating the foreground runtime also terminates its launcher and namespace init. (The OCI `run` rearms the signal after its own credential switch.) Workload credential changes, setuid/setgid or file-capability executables, and explicit changes to that signal setting can defeat this cleanup; stronger external supervision is a later milestone. Terminal relaying and graceful signal forwarding are not implemented yet. An outer container can restrict namespace or mount operations even when its user is root.

## Design

- Swift handles argument validation and the host-side command interface.
- Namespace setup, rootfs setup, process creation, startup-error reporting, and waiting are implemented in Swift. `namespace-run`, `run`, and `create` share one fork/unshare/fork launcher; each supplies its own init body. The synchronous launch API is unavailable directly from async contexts and rejects callers with more than one thread before it forks. Invoke it before starting background work; signal handlers must not introduce concurrent work during launch. Lifecycle commands are synchronous and single-threaded throughout; cross-process coordination uses `flock`, never an in-process lock.
- Only `Sources/ContainerRuntime/Kernel/` imports libc (`Musl` when available, otherwise `Glibc` on Linux, `Darwin` on macOS) and `LinuxAPI`; it exposes system calls as Swift API with `ENOSYS` stubs off Linux, and a unit test keeps other files from importing libc. A small header-only `LinuxAPI` module exposes missing GNU declarations and fixed-signature adapters for variadic `prctl`/`syscall`/`openat` (including `pivot_root`, which glibc does not wrap); it contains no launch or supervision logic. musl execution has not yet been tested.
- Descriptor operations and errors use [swift-system](https://github.com/apple/swift-system), currently resolved to 1.8.1. A noncopyable owner wraps its copyable `FileDescriptor`, closes on scope exit, and supports scoped borrowing, explicit closing, and ownership handoff. Scoped access keeps the owner alive through each descriptor operation. Pipe creation uses atomic close-on-exec behavior; Linux-specific namespace operations retain their libc bindings.
- The CLI uses [swift-argument-parser](https://github.com/apple/swift-argument-parser), currently resolved to 1.8.2. It preserves workload arguments after the required `--` separator. Usage errors exit 64; setup failures exit 125; workload exit statuses pass through.
- Every project-owned Swift target enables `.strictMemorySafety()` and treats warnings as errors. This checks Swift source and its C call sites; it does not verify libc or the header adapters.
- OCI `config.json` is decoded with `Decodable` (FoundationEssentials where available) into types that reject unknown keys, then validated into an immutable `OCIRunPlan`. Bundle and rootfs paths are canonical, absolute `FilePath` values.
- Argument, environment, and setup path bytes use Swift 6.4's `OutputSpan` initialization API in a single owned slab, arranged as NULL-terminated groups. A temporary `OutputSpan` owns the NUL-terminated pointer vector; its borrowed `Span` stays inside the C call. Audited `unsafe` expressions mark the raw-pointer boundary, with no manual Swift allocation/deallocation.

## Not yet implemented

The lifecycle lacks console sockets, no-pivot, foreground signal forwarding,
and hooks. Seccomp, custom devices, cgroup mounts, broader mount options and supplied namespace joins are also missing.
Terminals, user namespace mappings/rootless operation, additional process settings,
hugepages, block I/O, unified controls and exec sub-cgroups remain feature gaps.
Musl/static builds have not been verified.

The [roadmap](roadmap.md) resumes the kontainer-level feature journey after the
Swift refactor, beginning with engine contracts, mounts and namespace joins.
The [parity inventory](parity.md) distinguishes implemented-target gaps from runc
extensions; CPU realtime, cgroup v1 and systemd management are outside the pinned
target's implemented functionality. The [Docker assessment](docker-integration.md)
records the additional integration work and Linux acceptance gates. Docker support
has not been established.

### Device access rules

Nonempty `linux.resources.devices` lists are enforced by cgroup-v2 BPF before init
joins its group. `allow` and a nonempty `access` combination of `r`, `w`, `m` are
required. `type` is `a` (also absent/empty), `b` or `c`; absent/null/-1 major and
minor numbers are wildcards, otherwise UInt32 device numbers are required. There
are at most 512 effective input rules including the eleven standard appended
rules. Absent/empty device lists retain the existing unrestricted-leaf behavior;
ancestor device restrictions always remain effective.

Rules use runc's ordered reset/exception model. An `a` rule resets the default and
clears prior exceptions. Specific permissions merge or subtract; attempts to
punch a narrower hole in an existing wildcard fail validation. As in runc, the
standard runtime devices are appended after user rules, including wildcard
mknod allows and standard null/zero/full/random/TTY/PTY access. Partial deny
exceptions reject any overlapping access, including O_RDWR requests containing a
denied read or write bit. This is stricter than runc 1.4's combined-access subset
match. `linux.devices` inode creation remains unsupported.

Loading or attaching a requested program fails setup on any error, including
missing BPF support or privileges. The filter uses `BPF_F_ALLOW_MULTI`, preserves
external/ancestor filters, and records its program ID with the cgroup's inode and
boot ID. Normal and failure cleanup detach only that owned program; a supplied
cgroup and its pre-existing programs remain. Other resource updates retain the
filter and its saved rules; a device-rule update request is explicitly rejected.
See the [engine baseline](engine-baseline.md) for the verified profile.

### Bind mounts

`type: bind` or a `bind`/`rbind` option selects a host bind source; `type: none`
with bind options works too. Source paths must be nonempty and NUL-free; relative
sources are relative to the bundle. Sources are pinned before configured mounts
run. Files get regular-file target placeholders; directories get directory
placeholders, with missing parent directories created safely inside the root.
Existing absolute/relative target symlinks resolve in-root, including `..` inside
a symlink target. Magic links, type mismatches, dangling target links and binds
over `/proc` fail explicitly. The rootfs still requires a single owner during
setup; this does not add a concurrent-host-writer guarantee.

Unmentioned inherited bind attributes stay unchanged. `ro`/`rw`, `nosuid`/`suid`,
`nodev`/`dev`, `noexec`/`exec` select set/clear operations; the last explicit mode
wins. `strictatime` changes the atime mode. Attributes are applied to the detached
clone before attachment and never change the host source mount. `rbind` includes
submounts, while ordinary `ro` changes only the top mount, matching runc. Private
and recursive-private propagation are supported; other propagation modes,
explicit `remount`, idmapping and recursive attributes remain rejected. Bind
attribute/propagation changes require Linux 5.12+ (`mount_setattr`); basic clones
use the existing Linux 5.2+ descriptor mount API.

The [engine baseline](engine-baseline.md) records the pinned native-snapshotter
Alpine scenario, complete with original create JSON and its remaining exclusions.
