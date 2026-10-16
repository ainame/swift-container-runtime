# swift-container-runtime

An educational Linux container runtime in Swift. [runc](https://github.com/opencontainers/runc) is the behavioral reference; [kontainer-runtime](https://github.com/ternbusty/kontainer-runtime) is a companion implementation and the initial feature target.

> **Educational status.** This is a learning project, not a production runtime. It implements a narrow subset of the OCI runtime specification and **is not a security boundary**: there are no capability, seccomp, no_new_privs, cgroup, user-namespace, masked-path, or read-only controls yet. Workloads run as root with the caller's privileges.

Two commands exist so far:

- `run` (roadmap phase 2) runs an OCI bundle in the foreground with its own root filesystem, using a deliberately small subset of `config.json`. Unsupported fields are rejected.
- `namespace-run` (phase 1) is a **namespace lab**. It creates new UTS, PID, and mount namespaces, makes mount propagation private, mounts `/proc` for the new PID namespace, and executes a command. It shares the surrounding Linux filesystem.

## Run an OCI bundle

```sh
swift build
sudo .build/debug/swift-container-runtime run --bundle /path/to/bundle mybox
```

Requires root and Linux 5.11 or later: `close_range` with `CLOSE_RANGE_CLOEXEC` (5.11; plain `close_range` is 5.9). `namespace-run` still needs only 5.3. `--bundle` (`-b`) defaults to the current directory, like runc. The runtime reads `config.json`, sets up the container, waits for the workload, and exits with its status. Setup failures exit 125 and print the failing step. Usage errors exit 64. The container ID is validated with runc's character rules, but no state is stored until phase 3, so it is not checked for duplicates and there is no `state`, `kill`, or `delete`.

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

`runc spec` output does not run unchanged, because it asks for a terminal, capabilities, rlimits, masked/read-only paths, and more. This runtime rejects those fields instead of ignoring them.

### Supported subset

| Field | Supported |
| --- | --- |
| `ociVersion` | `1.x` |
| `root.path` | Relative to the bundle or absolute, non-empty, without NUL; resolved to a canonical directory other than `/`. Bundle and rootfs paths must be valid UTF-8. `root.readonly` must be absent or `false`. |
| `process.args` | `args[0]` must be an **absolute path** inside the rootfs; there is no `PATH` search. |
| `process.env` | `NAME=value` entries without NUL; all are validated, then, as in runc, the last occurrence of a name wins (kept in the order of those last occurrences). This is the **entire** environment: nothing is inherited from the caller and, unlike runc, no `HOME` is added. |
| `process.cwd` | Absolute, without `.`/`..`; created if missing (as in runc). |
| Container paths | `process.cwd` and mount destinations are limited to 128 components and 4095 bytes. |
| `process.user` | Only `uid: 0, gid: 0`. Supplementary groups are cleared. |
| `process.terminal` | Absent or `false`; stdio is inherited directly. |
| `hostname` | Requires a `uts` namespace. |
| `linux.namespaces` | New `mount` (required), `pid`, `uts`, `ipc`, `network` namespaces. No `path` joins. The network namespace is left unconfigured; even loopback is down. |
| `linux.rootfsPropagation` | Absent, `private`, or `rprivate`; propagation is always made `rprivate`. |
| `mounts` | `proc` at `/proc` (requires a `pid` namespace), `tmpfs` anywhere, `devpts` at `/dev/pts`. Flags: `nosuid`, `nodev`, `noexec`, `strictatime`. Data: tmpfs `mode=`/`size=`; devpts `newinstance`, `ptmxmode=`, `mode=`, `gid=`. |
| `/dev` | With a tmpfs at `/dev`, creates `null`, `zero`, `full`, `random`, `urandom`, `tty` (via `mknod`) and the `fd`, `stdin`, `stdout`, `stderr` links, plus `ptmx` when devpts is mounted. Without a `/dev` tmpfs, `/dev` is left as the rootfs provides it. |
| `annotations` | Accepted and ignored. They do not affect behavior. |

Every other field is rejected with its JSON path, for example `config.json: unsupported field(s): process.capabilities`. This includes hooks, capabilities, rlimits, `noNewPrivileges`, `apparmorProfile`, seccomp, cgroups/resources, devices, masked/read-only paths, sysctl, user/cgroup/time namespaces, ID mappings, bind mounts, other filesystem types, `ro`, and propagation options.

### Setup sequence

Validation builds an immutable plan before any process is created. The launch then follows these steps:

1. Fork a launcher. It unshares the requested namespaces and makes `/` `rprivate`, so later mounts stay in the new namespace.
2. Fork the namespace init (PID 1 with a `pid` namespace). It immediately marks every descriptor from 3 upward close-on-exec with `close_range(CLOSE_RANGE_CLOEXEC)`, so descriptors inherited from the caller (such as a directory outside the rootfs) never reach the workload. Marking rather than closing keeps the setup-error pipe usable until `execve`. Unsupported kernels fail setup. Only stdin, stdout, and stderr are passed through.
3. In the init, open the canonical rootfs with `O_PATH|O_NOFOLLOW`, bind-mount that descriptor onto the rootfs path, reopen the path with `O_NOFOLLOW`, and require the same device and inode.
4. Resolve each mount destination from that descriptor one component at a time with `openat(O_PATH|O_DIRECTORY|O_NOFOLLOW)`, creating missing directories with `mkdirat`. A symlink component fails setup, whether it is absolute or relative and whether it points inside or outside the rootfs. Runc instead resolves such links within the rootfs. The mount itself targets `/proc/self/fd/N`, so no path is re-walked between check and use. `proc` is mounted from inside the new PID namespace.
5. Populate `/dev`.
6. Call `pivot_root(".", ".")` as runc does. Then `fchdir` to the old root, detach it with `umount2(MNT_DETACH)`, and close both root descriptors.
7. Set the hostname, create and enter the cwd, clear supplementary groups, set uid/gid 0, and call `execve` with the configured environment.

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

The command runs as PID 1, so normal Linux PID 1 signal behavior applies. The runtime waits for it and forwards its exit status. For ordinary workloads retaining their parent-death signal setting, terminating the foreground runtime also terminates its launcher and namespace init. Credential changes, setuid/setgid or file-capability executables, and explicit changes to that signal setting can defeat this cleanup; stronger external supervision is a later milestone. Terminal relaying and graceful signal forwarding are not implemented yet. An outer container can restrict namespace or mount operations even when its user is root.

## Toolchain and checks

The package requires Swift tools 6.4. `.swift-version` selects the macOS 6.4.0 release without changing your global toolchain. Linux tests use the explicit `swift:6.4.1` image and a separate build directory. `Package.resolved` records the CLI dependency resolution.

```sh
swift test
```

Strict memory diagnostics and warnings-as-errors are package settings, so ordinary builds and tests enforce them automatically. GitHub Actions runs the unit tests and debug/release namespace and OCI checks in the pinned Swift 6.4.1 Linux image.

## Development on macOS

The commands perform Linux kernel operations; macOS builds cannot run containers or the namespace lab directly. Unit tests for configuration decoding and validation run on macOS. Use a Linux VM or Apple's [`container`](https://github.com/apple/container) command to build and test the Linux executable.

Run the complete Linux build, unit tests, and privileged integration checks from macOS:

```sh
container system start
scripts/test-linux.sh
```

The script uses a disposable VM-backed `swift:6.4.1` container and stores Linux build products separately in `.build/linux-6.4.1`. It runs debug and optimized integration checks for namespaces, procfs, surrounding hostname/mount preservation, exit and signal status, argument handling, permission failures, and parent-death cleanup.

Inside the VM it also installs `busybox-static` and `runc` and runs `scripts/oci-integration.sh`. That script builds a static BusyBox rootfs and runs the same bundles through this runtime and runc. Both must satisfy the shared checks: PID 1, rootfs contents and isolation from host files, hostname, cwd, environment replacement, device nodes, separate stdout/stderr, exit 42, and missing executables. Runtime-specific checks cover exit 125 diagnostics, rejected configurations, symlink escapes from mount destinations (absolute and relative), and setup failures after partial mounting. Those failures must not run the workload or change host mounts and hostname. Set `RUNC_COMPARE=0` to skip runc, or `RUNC_COMPARE=1` to require it.

The local development environment has Apple `container` 0.9.0 and a cached `swift:6.4.1` image. That installation has no `container machine` subcommand. A successful Swift build inside an Apple container checks Linux compilation; a namespace smoke test must separately demonstrate that its guest environment grants the required kernel capabilities.

## Design

- Swift handles argument validation and the host-side command interface.
- Namespace setup, rootfs setup, process creation, startup-error reporting, and waiting are implemented in Swift. `namespace-run` and `run` share one fork/unshare/fork launcher; each supplies its own init body. The synchronous launch API is unavailable directly from async contexts and rejects callers with more than one thread before it forks. Invoke it before starting background work; signal handlers must not introduce concurrent work during launch.
- libc imports select `Musl` when available, otherwise `Glibc` on Linux (`Darwin` for portable macOS code). A small header-only `LinuxAPI` module exposes missing GNU declarations and fixed-signature adapters for variadic `prctl`/`syscall`/`openat` (including `pivot_root`, which glibc does not wrap); it contains no launch or supervision logic. musl execution has not yet been tested.
- Descriptor operations and errors use [swift-system](https://github.com/apple/swift-system), currently resolved to 1.8.1. A noncopyable owner wraps its copyable `FileDescriptor`, closes on scope exit, and supports scoped borrowing, explicit closing, and ownership handoff. Scoped access keeps the owner alive through each descriptor operation. Pipe creation uses atomic close-on-exec behavior; Linux-specific namespace operations retain their libc bindings.
- The CLI uses [swift-argument-parser](https://github.com/apple/swift-argument-parser), currently resolved to 1.8.2. It preserves workload arguments after the required `--` separator. Usage errors exit 64; setup failures exit 125; workload exit statuses pass through.
- Every project-owned Swift target enables `.strictMemorySafety()` and treats warnings as errors. This checks Swift source and its C call sites; it does not verify libc or the header adapters.
- OCI `config.json` is decoded with `Decodable` (FoundationEssentials where available) into types that reject unknown keys, then validated into an immutable `OCIRunPlan`. Bundle and rootfs paths are canonical, absolute `FilePath` values.
- Argument, environment, and setup path bytes use Swift 6.4's `OutputSpan` initialization API in a single owned slab, arranged as NULL-terminated groups. A temporary `OutputSpan` owns the NUL-terminated pointer vector; its borrowed `Span` stays inside the C call. Audited `unsafe` expressions mark the raw-pointer boundary, with no manual Swift allocation/deallocation.

## Not yet implemented

Lifecycle commands and state (`create`, `start`, `state`, `kill`, `delete`, detached `run`, `list`) are planned for phase 3. Credentials other than root, capabilities, no_new_privs, rlimits, seccomp, cgroups, masked/read-only paths, read-only rootfs, and hooks are planned for phase 4. Terminals, signal forwarding, `exec`, user namespaces, and rootless operation are planned for phase 5. Bind mounts, other filesystem types, PATH lookup, `HOME` defaulting, network setup, and the rest of the phase 6 inventory are also missing. musl builds have not been verified. See the [implementation roadmap](docs/roadmap.md) for the path toward kontainer-runtime feature parity.
