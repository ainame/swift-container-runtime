# Code organization

Keep each group responsible for one resource, format, or runtime phase. Prefer an
instance method when an operation uses an owned resource or prepared inputs, an
extension when an existing type already supplies the context, and a small static
namespace for stateless operations. Keep helpers local to their only caller when
possible. A top-level function needs a concrete reason.

Implement formats natively in Swift instead of emulating Go's standard library:
for example `Duration(parsing:)` for intervals, `debugDescription` for quoting
values in diagnostics, `Encodable` types with `JSONEncoder` for JSON output, and
Foundation's ISO 8601 style for timestamps. Keep what consumers depend on (JSON
key names and which keys are present, hugetlb size keys, which executable a
lookup chooses) and let Swift decide formatting such as key order, number
spelling, escaping and fractional-second digits.

## Directories

`Sources/ContainerRuntime` groups files by runtime phase:

| Directory | Responsibility |
|---|---|
| `Specification/` | Bundle and `config.json` decoding, validation into `OCIRunPlan`/`OCIProcessPlan`, the starter spec, features metadata |
| `Launch/` | The fork handshake, rootfs and workload setup, the start gate, pidfd hand-off, descriptor preservation |
| `Lifecycle/` | Container commands, state records and their directories, live observation, PID files, `ps` |
| `Cgroups/` | cgroup v2 placement, resource plans and updates, interface-file parsing, statistics |
| `Events/` | Event snapshots and JSON, the inotify watch, tick scheduling, timestamps and duration text |
| `System/` | Owned descriptors, procfs, verified processes, runtime errors |
| `Kernel/` | The only files that import libc and `LinuxAPI`: system calls as Swift API, with `ENOSYS` stubs off Linux |

A file belongs where its main type's responsibility lies; a Linux extension of a
type sits beside that type.

Only `Kernel/` imports `Glibc`, `Musl`, `Darwin` or `LinuxAPI`, and only
`Kernel/` checks the platform with `#if`; `KernelBoundaryTests` enforces the
imports. Every runtime file therefore compiles on macOS, where Linux-only
operations fail with `ENOSYS` and `Kernel.isLinux` is false.

Byte I/O uses safe buffer types: `Kernel.File.write` and `Kernel.Socket.send`
take a `RawSpan` (pass `array.span.bytes`), and `Kernel.File.read`/`readAll`
return arrays, so unsafe buffer pointers stay inside Kernel. Fixed records such
as `LaunchRecord` encode their fields explicitly rather than reinterpreting a
struct's memory. swift-system's own Span-based I/O (apple/swift-system#290)
can replace these once it ships in a tagged release; it is only on the
`staging` branch so far. Kernel API takes and returns Swift types such as `FileStatus`,
`PollEvents`, `Errno` and descriptors, and names libc's `pid_t`, `uid_t` and
`gid_t` for the rest of the runtime. A new system call goes into Kernel with a
stub for other platforms. See [the migration plan](platform-shim-plan.md).

Do not annotate a closure `throws(Errno)` when passing it to an untyped
`throws` parameter such as `OwnedFileDescriptor.withDescriptor`: Swift 6.4.1
on Linux crashes in SILGen on the conversion thunk. Let the closure take the
parameter's type and catch `Errno` cases at the call site.

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
`Duration(parsing:)`, and `ProcessHandle.withVerified`.

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
- Public command APIs return `ExitStatus`, carrying the same shell-style
  number (exit code, or 128 plus the signal number). Internally this status
  remains `Int32`; convert only when returning from a public method. The
  shell convention cannot distinguish an explicit exit code from signal death.
  Child-side values passed to `_exit` also remain `Int32`, including launch
  failure status 125.
- Timeouts are `Duration`; `Duration.pollTimeout` converts at the poll(2) call.
- PIDs are libc's `pid_t`. It is an alias, but it matches the man pages.
- Namespaces are `OCIRunPlan.Namespace`; `cloneFlag` converts before fork.
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

During implementation, run affected unit tests and focused Linux debug integrations.
A launch or Kernel change needs the relevant lifecycle/setup suites, but does not
require a release build on each edit or commit. At review or milestone completion,
use the full debug/release gate once for the candidate, locally or in CI:

```sh
sh scripts/test-linux.sh --configuration all
```

See [validation tiers](testing.md#validation-tiers) for broad-change coverage and
when to rerun checks.

`CSeccomp` is a Linux-only system-library binding to the host libseccomp. Only
`Kernel/Seccomp.swift` imports it. `Specification/SeccompProfile` owns strict OCI
validation and the persisted policy; `WorkloadSetup` owns load ordering shared by
init and exec. Library filter construction and memfd export happen before fork;
the child uses the prepared bytes with seccomp(2), without library construction.
