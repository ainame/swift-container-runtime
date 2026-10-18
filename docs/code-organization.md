# Code organization

Keep each group responsible for one resource, format, or runtime phase. Prefer an
instance method when an operation uses an owned resource or prepared inputs, an
extension when an existing type already supplies the context, and a small static
namespace for stateless operations. Keep helpers local to their only caller when
possible. A top-level function needs a concrete reason; `parseGoDuration` remains
as a compatibility entry point for existing library clients.

## Boundaries

- `ProcFS` reads kernel information. `ProcessHandle` verifies and pins a live
  process through a pidfd, then provides scoped signalling and exit waits.
  `OwnedFileDescriptor` supplies descriptor operations independent of processes.
- `StateRoot` controls directory membership. `ContainerDirectory` owns one pinned
  generation and reads its files. `LockedContainer` adds mutation authority.
  `ContainerObservation` combines records with live process, gate, and cgroup
  state. Status is derived rather than cached.
- `NamespaceLauncher` coordinates the synchronous fork handshake. `LaunchRecord`
  and `LaunchControl` encode its messages. `StartProtocol` implements the start
  client and packets, while `StartGate` serves them inside the created init.
- `RootFilesystemSetup` prepares mounts, devices, root transition, hostname, and
  paths. `WorkloadSetup` applies process settings and executes the workload;
  both initial launch and exec use it.
- `CgroupStatsReader` collects statistics, `CgroupFile` parses controller files,
  and `ContainerStats` represents and encodes a snapshot. `EventWatch` watches
  the kernel and state directories; `EventSchedule` supplies timing arithmetic.
- CLI option groups own shared options and validation. `CommandValidation`
  adapts validation errors, and `CommandFailure` reports execution failures.

## Naming

Read the type and method together. Use `LaunchRecord.read(from:)`,
`LaunchControl.send(over:)`, and `RFC3339.format(...)` without repeating the
owning type in the method name. Retain words and labels that convey an essential
operation, unit, or safety condition: `BundleConfiguration.resolveDirectory`,
`GoDuration.nanoseconds(from:)`, and `ProcessHandle.withVerified`.

Keep internal helpers private where possible. A short name must still describe
what a caller can rely on; comments explain ordering and invariants rather than
compensating for vague names. Qualify libc calls where a method has the same name.

## Integer types

Don't add typealiases for integer roles: Swift treats an alias as the same type,
so it labels a value without checking it. Use an existing type that carries
the meaning, and add a small type only when values are easy to mix up:

- errno values are `Errno?` (nil on success) or a thrown `Errno`; read
  `Errno.current` right after the failing call. Child-side launch steps return
  `Errno?` or `LaunchFailure?` so each step reports and exits explicitly.
- Descriptors are `FileDescriptor` or `OwnedFileDescriptor` outside raw
  syscall and post-fork mount code.

Raw `Int32` remains for C call results and `LaunchRecord`'s fixed wire fields.

## Lifetime and execution constraints

`RootFilesystemSetup` and `WorkloadSetup` are explicitly unsafe views over C
buffers, constructed and used inside the enclosing string/group buffer scopes.
They do not own descriptors or extend pointer lifetimes. Each fork branch still
closes its own descriptor subset explicitly. Preserve credential, capability,
resource-limit, and handshake ordering when extracting methods.

The CLI and pre-fork path remain synchronous and single-threaded. Cross-process
`flock` scopes remain synchronous and never suspend. Kernel event monitoring
continues to use inotify and polling; Swift Observation is appropriate only if a
future consumer keeps an in-process model of the resulting snapshots.

Run the affected Linux integrations for incremental refactors. Launch changes
need the full debug and release gate with Swift 6.4.1:

```sh
sh scripts/test-linux.sh --configuration all
```
