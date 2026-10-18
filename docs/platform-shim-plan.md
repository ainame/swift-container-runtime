# Plan: a Swift `Kernel` layer that compiles everywhere

Goal: `ContainerRuntime` stops importing libc and stops using `#if os(Linux)`
(today: 29 files with conditional `Musl`/`Glibc`/`Darwin` imports, 18 files
wrapped whole in `#if os(Linux)`, 45 inner blocks). Linux behavior is
unchanged; on macOS every Linux-only operation fails at runtime with `ENOSYS`,
so all runtime code type-checks there.

## Decisions

- **Layers stay separate.** `LinuxAPI` remains a C module only for C APIs
  Swift cannot call well (variadic `prctl`, raw `syscall`, `CMSG_*` macros,
  the mount API). It gets no platform policy and no stubs.
- **No `@_exported import Glibc`.** Re-exporting libc would put all of it into
  every file and every client.
- **`Kernel` is a directory, not a module:** `Sources/ContainerRuntime/Kernel/`.
  Swift imports are per file, so only Kernel files import libc
  (`Musl`/`Glibc`/`Darwin`, conditionally) and `LinuxAPI`, and no other
  runtime file sees them. A separate module would add `package`/`public`
  modifiers to every wrapper without hiding anything more: what keeps C out of
  the rest of the runtime is that Kernel's API uses only Swift types
  (`FileStatus`, option sets, `Errno`, descriptors, and C string pointers on
  post-fork paths). It can become a module later if another target needs it.
- **The boundary is checked:** a unit test fails when a runtime file outside
  `Kernel/` imports `Glibc`, `Musl`, `Darwin` or `LinuxAPI`. Files not yet
  migrated are listed in the test and removed step by step.
- **Only Kernel has platform conditionals.** Each Kernel file has a Linux
  implementation and a stub implementation; nothing else checks the platform.

## Inventory (what Kernel must cover)

From the 29 importing files:

- About 90 libc functions. Most used: `_exit`, `fork`, `waitpid`, `getpid`,
  `getppid`, `geteuid`/`getegid`, `stat`/`fstat`/`fstatat`/`fstatfs`/`statvfs`,
  `unlinkat`/`mkdirat`/`renameat`/`symlinkat`/`mknodat`, `readdir`/
  `opendir`/`fdopendir`/`closedir`, `flock`, `fsync`, `chdir`/`fchdir`/
  `chroot`, `umask`, `setuid`/`setgid`/`setgroups`/`setsid`, `execve`/`execv`,
  `posix_spawnp` and its file actions, `sendmsg`/`bind`/`listen`/`dup`/`pipe`,
  `clock_gettime`, `getpwuid`, `realpath`, `access`, `fchown`, `sethostname`,
  `unshare`/`setns`/`mount`/`umount2`, `inotify_init1`/`inotify_add_watch`,
  `fcntl`.
- All 29 `linux_*` adapters in `LinuxAPI`.
- About 18 types: `stat` (36 uses), `pid_t`, `mode_t`, `dev_t`, `uid_t`/`gid_t`,
  `statvfs`, `pollfd`, `sockaddr_un`, `msghdr`/`cmsghdr`/`iovec`, `timespec`,
  `dirent`, `posix_spawn_file_actions_t`.
- `errno` and the `E*`, `O_*`, `AT_*`, `MS_*`, `CLONE_*`, `IN_*`, `SIG*`,
  `RLIMIT_*` constants.

## Kernel API shape

- **Functions return Swift results** where that is natural:
  `throws(Errno)`, `OwnedFileDescriptor` or `FileDescriptor`, and Swift value
  types such as `FileStatus` (dev, inode, mode, rdev, uid) instead of `stat`.
- **Post-fork paths must not allocate.** Wrappers used between `fork` and
  `exec` take C strings/pointers and return `Errno?` or raw descriptors, never
  `String` or arrays. Throwing a plain `Errno` is fine.
- **Names are grouped by area** (Kernel is an `enum` namespace): `Kernel.Process` (fork, wait, exit, exec,
  credentials, parent-death signal, capabilities, limits), `Kernel.File`
  (open/stat/directory/link/flock), `Kernel.Mount` (mount, pivot_root, the
  descriptor mount API), `Kernel.Namespace` (unshare, setns, clone flags),
  `Kernel.Socket` (Unix sockets, SCM_RIGHTS, poll), `Kernel.Notify` (inotify),
  `Kernel.Pidfd`.
- **Constants as Swift types** where they form sets: `MountFlags`
  (`OptionSet`), `OCIRunPlan.Namespace` for clone flags, `ResourceLimit`
  numbers; plain `Int32` statics otherwise.
- **`errno`:** `Errno.current` lives in Kernel; `ContainerRuntime` never
  reads `errno` directly.
- **No `@inlinable`** unless a measurement justifies it: syscall cost
  dominates, and it would expose implementations in the module interface.

## Migration (one commit each, Linux gate per step)

1. **Done.** `Kernel/` with `Errno.current`, the `pid_t`/`uid_t`/`gid_t`
   names, `FileStatus`/`FileIdentity`, `PollEvents` polling, directory
   listing and pidfds, plus `KernelBoundaryTests`. `ProcFS`, `ProcessHandle`,
   `ContainerState` and `RuntimeError` no longer import libc.
2. **Done.** Files and directories: `Kernel.File` gained `open` (also
   relative to a borrowed `OwnedFileDescriptor`), `makeDirectory`, `remove`,
   `rename`, `synchronize`, `resolvedPath`, `isOnCgroup2`, `lock`/`unlock`, path listing;
   `Kernel.Process` gained effective IDs, `userName(of:)` and `sleep(for:)`;
   `Kernel.Math` wraps libm. `StateStore`, `PIDFile`, `BundleConfiguration`,
   `DefaultSpecification`, `Cgroup` and `CgroupPlan` no longer import libc.
3. **Done.** Events: `Kernel.Notify` (open, watch, drain) with `NotifyEvents`; `EventWatch` waits through `OwnedFileDescriptor.poll`.
4. **Done.** Lifecycle and supervision: `Kernel.Socket` (Unix sockets,
   exact `sun_path` addresses, MSG_NOSIGNAL sends, SCM_RIGHTS),
   `Kernel.Process` (spawn, wait, signal, exec, monotonic time) and
   `Kernel.Signal`; `poll` reports `.error` on failure. `ContainerLifecycle`,
   `ContainerObservation`, `ProcessTable`, `StartGate`, `PidfdSocket`,
   `PreservedDescriptors`, `OCIRunPlan`, `LinuxDevice` and
   `LinuxRuntimeError` no longer import libc.
5. **Done.** Launch: `Kernel.Mount` (`MountFlags`, mount, detached unmount,
   pivot_root, statvfs flags, the descriptor mount API with owned results),
   `Kernel.Namespace`, `Kernel.Credentials` (groups, IDs, no_new_privs,
   capabilities, rlimits), more `Kernel.Process` (fork, exit, session,
   parent-death signal, umask, hostname, chdir/chroot, close-on-exec marking,
   execv) and C-string `Kernel.File` overloads for the child path.
   `RootFilesystemSetup.prepare` became named steps in runc's order, and
   `PathControls` uses `OwnedFileDescriptor` instead of raw descriptors.
   No runtime file outside `Kernel/` imports libc.
6. Remove every remaining `#if os(Linux)` and libc import from
   `ContainerRuntime`; public `…OnLinux`/`unsupported` branches call the
   implementation directly.
7. Docs: `docs/code-organization.md` (Kernel is the only platform import;
   new system calls go into Kernel with a stub) and AGENTS.md.

Tests keep `#if os(Linux)` where they exercise real kernel behavior.

## Validation

- macOS: `swift build` and `swift test` after every step; from step 6 on,
  macOS type-checks all runtime code.
- Linux: the affected suites per step, and the full gate
  (`sh scripts/test-linux.sh --configuration all`) for steps 4 to 6.

## Cost and risk

The change touches all 29 files and adds several hundred lines under
`Kernel/`. The main risks are allocation or ordering changes on post-fork paths
(step 5) and Darwin type differences surfacing in stubs (`dev_t`, `mode_t`
widths, `msghdr` fields), which stay inside Kernel.

## Remaining readability items

- Name the steps inside `RootFilesystemSetup.prepare` and `WorkloadSetup.configure`.
- An owned descriptor type for post-fork mount code in `PathControls`.
