# Plan: compile everywhere through a stubbed kernel layer

Goal: remove the per-file `canImport(Glibc/Musl/Darwin)` blocks (29 files) and
the `#if os(Linux)` wrappers (18 whole files, 45 inner blocks) without splitting
targets. Linux behavior is unchanged; on macOS every Linux-only call fails at
runtime with `ENOSYS`, so all code still type-checks there.

## Findings

- Most kernel-specific work already goes through the `LinuxAPI` C shim
  (`linux_pidfd_open`, `linux_open_path`, mount API, capabilities, sockets).
- Remaining direct Linux-only uses in Swift: `unshare`, `setns`, `mount`
  (Darwin's has a different signature), `umount2`, `inotify_init1`/`add_watch`,
  `accept4`, `close_range`, `posix_spawn_file_actions_t()` initialization, and
  constants `MS_*`, `CLONE_NEW*`, `MNT_DETACH`, `IN_*`, `MSG_NOSIGNAL`,
  `ST_NOSYMFOLLOW`, Linux-only `RLIMIT_*` (LOCKS, SIGPENDING, MSGQUEUE, NICE,
  RTPRIO, RTTIME).
- A single file with `@_exported import` makes a module visible to every file
  of the target (verified with a probe package; without it `getpid` is not
  found). Caveat: it also re-exports to clients (RuntimeCLI, tests), and
  `@_exported` is underscored but widely used.

## Steps

1. **Shim on every platform.** In `Package.swift`, depend on `LinuxAPI`
   unconditionally (ContainerRuntime and ContainerRuntimeTests). In
   `LinuxAPI.h`, keep the `#if defined(__linux__)` branch and add an `#else`
   branch that includes Darwin headers, defines the missing constants with
   their Linux values, and implements each `linux_*` function as
   `errno = ENOSYS; return -1;`.
2. **Finish the shim.** Add `linux_unshare`, `linux_setns`, `linux_mount`,
   `linux_umount2`, `linux_inotify_init1`, `linux_inotify_add_watch`,
   `linux_close_range` (or fold into `linux_mark_descriptors_cloexec`), and
   replace direct Swift calls. Wrap Linux-only `RLIMIT_*` and `IN_*`/`MS_*`
   constants as shim defines so Swift sees one name on both platforms.
3. **One import file.** Add `Sources/ContainerRuntime/System/Platform.swift`:
   ```swift
   #if canImport(Glibc)
   @_exported import Glibc
   #elseif canImport(Musl)
   @_exported import Musl
   #elseif canImport(Darwin)
   @_exported import Darwin
   #endif
   @_exported import LinuxAPI
   @_exported import SystemPackage
   ```
   Delete the conditional import blocks from every other source file.
   (AGENTS.md's "preserve conditional Musl/Glibc imports" still holds, in one place.)
4. **Drop `#if os(Linux)`.** Remove whole-file wrappers, then inner blocks.
   Public methods that branch to `…OnLinux` or `throw Self.unsupported` call
   the implementation directly; on macOS it fails with ENOSYS (or a procfs
   read error). Fix Darwin type differences where they surface (`msghdr`
   field widths, `posix_spawn_file_actions_t`, `dirent` sizes) with
   `numericCast` or a shim helper, not `#if`.
5. **Tests.** Leave Linux-behavior tests behind `#if os(Linux)`; they need a
   real kernel. Only source files lose their conditionals.
6. **Docs.** Update `docs/code-organization.md` (Platform.swift is the only
   import point; new Linux calls go into the shim with a Darwin stub) and
   AGENTS.md wording.

## Validation

- macOS: `swift build` and `swift test` (now type-checking all Linux code).
- Linux: full gate, `sh scripts/test-linux.sh --configuration all`, because
  launch and post-fork code are touched.
- Optional: `swift build --swift-sdk aarch64-swift-linux-musl` to exercise
  the Musl path without a VM.

## Later (separate change)

A typed Swift `Kernel` namespace over the shim (`throws(Errno)`, owned
descriptors) can replace raw `guard … == 0 else { errno }` patterns area by
area, starting with launch. It needs no `#if`, must not allocate on post-fork
paths, and should skip `@inlinable` unless measurements justify it.

## Remaining readability items

- Name the steps inside `RootFilesystemSetup.prepare` and `WorkloadSetup.configure`.
- An owned descriptor type for post-fork mount code in `PathControls`.
