# Feature parity roadmap

The goal is the **same level of functionality as kontainer-runtime**, expressed
through readable, native Swift code. Matching every runc behavior is not a goal.
runc remains a useful source for OCI semantics, security ordering, and differential
tests; differences in diagnostics, formatting, validation timing, or bootstrap
overhead do not require work unless a supported consumer depends on them.

This plan resumes feature work after the Swift refactor. It is based on source
inspection on 2026-10-18 at Swift commit `8d21065` and kontainer-runtime
[`357b8f2`](https://github.com/ternbusty/kontainer-runtime/tree/357b8f295a7fad450c822c61e79cf22f75546640).
The [parity inventory](parity.md) records coverage and deliberate differences;
the [Docker assessment](docker-integration.md) defines a separate integration gate.
No new Linux or Docker execution results are implied by this planning review.

## Baseline after the refactor

The lifecycle and observability foundation is substantial: create/start/run,
nonterminal exec, persistent state and process identity checks, kill/delete,
pause/resume, ps, events, update, spec/features/version, descriptor preservation,
and pidfd handoff are implemented. Rootfs isolation, basic mounts/devices,
credentials, five capability sets, rlimits, read-only roots and path controls,
and cgroup v2 memory/pids/CPU/cpuset controls have existing Linux integration suites.
Those suites are regression assets; their existence is not proof of a fresh pass.

The remaining gap is mainly **breadth of OCI setup and supervisor integration**.
A normal engine-generated bundle still requests unsupported mounts, namespace
paths, device rules, security settings, and CLI options. Command-name coverage
therefore overstates readiness; a percentage based on command names would mislead.

Build on the current boundaries rather than introduce another architecture:

| Existing boundary | Future work belongs here |
| --- | --- |
| `Specification/` (`OCIConfiguration`, `OCIRunPlan`, `OCIProcessPlan`) | Typed decoding, validation, and prepared plans for each new surface. |
| `Launch/RootFilesystemSetup` | Mounts, devices, root transition, sysctl and setup ordering. |
| `Launch/WorkloadSetup` | Settings shared by init and exec; avoid implementing each twice. |
| `Launch/NamespaceLauncher`, `ExecNamespaceSet`, launch/start protocols | Namespace joins/maps, console and hook handshakes; preserve process ownership and readiness. |
| `Cgroups/`, `Lifecycle/`, `Events/` | Additional controls, stored configuration, updates, cleanup and reporting. |
| `Kernel/` | System calls and platform stubs; libc imports stay here. |
| `RuntimeCLI/` | Human options and the specific runc CLI contract consumed by containerd. |

Keep CLI launch and pre-fork setup synchronous and single-threaded. Async APIs,
actors and structured tasks are appropriate for later supervision only where they
preserve that constraint. Preserve noncopyable descriptor ownership, scoped unsafe
buffers, strict memory safety, warnings-as-errors, and Swift 6.4
(6.4.1 on Linux). Discuss external dependencies, including a possible
libseccomp binding, before adopting them. See [code organization](code-organization.md).

## Ordered milestones

Each milestone is a series of small implementation commits, not one large rewrite.
Update the inventory and feature report with each supported increment. Keep
unsupported behavior explicit; do not make engine bundles work by discarding
security fields.

| Order | Deliverable and scope | Completion evidence on Linux |
| --- | --- | --- |
| 1. Engine contract baseline | Capture containerd/go-runc invocation arguments and real OCI bundles from pinned engine versions. Add global `--log`, `--log-format`, `--debug` support with useful errors; check version/features output and detached PID publication. Cover `kill --all`, especially shared PID namespaces. Record handling of optional no-pivot/keyring flags without pretending systemd cgroups exist. | Replay captured argv and JSON through the CLI; exercise failed create/start/exec and PID-file publication under a real subreaper, with no leaked tasks, FDs, state or cgroups. A captured failure is a baseline, not Docker support. |
| 2. Practical rootfs and namespace support | Bind/rbind mounts for files and directories, remount flags, common propagation, sysfs, mqueue, shm and cgroup2 mounts; custom devices and mount destinations that resolve symlinks safely inside the root. Join supplied namespace paths, support cgroup namespaces and common host/shared combinations. Keep user/time namespaces for milestone 7. | Ordinary image-derived bundles work through direct create/start and exec. Check mount flags, namespace inode identities, volume/resolv.conf/hosts mounts, host isolation, invalid joins, readonly combinations and cleanup against real workloads. |
| 3. Rootful containerd vertical slice | Use the existing runc v2 shim with the Swift binary. Implement only additional contract gaps discovered from the captured bundle and trace. Start with a declared cgroupfs profile, nonterminal workloads and explicit security limitations. | `ctr` runs an image, attaches pipes, creates/starts, performs detached exec with PID files, reports nonzero exits, kills and deletes; shim reaping and failure cleanup work. Pin image digests and engine/tool versions. This is a constrained engine milestone, not normal Docker defaults. |
| 4. Default security and hooks | Seccomp actions/architectures/argument rules needed by engine profiles, device-cgroup BPF rules, OOM score adjustment, session keyring setup, and AppArmor/SELinux execution-context availability. Add all six hook phases with namespace placement, state JSON stdin, environment, timeout and failure handling. | Allowed and denied syscalls/devices prove enforcement; init and exec receive the intended policy. Hooks prove ordering, timeout, reaping and cleanup. Supported host LSM profiles apply; unavailable requested security fails clearly. Re-run the containerd slice with its normal security configuration. |
| 5. Terminal and attached use | PTY setup, controlling terminal, initial size, console-socket FD handoff for create/run/exec, local foreground I/O, signal forwarding and terminal restoration. | Interactive shell plus noninteractive TTY workloads, EOF, resize through the shim, signal/exit propagation, non-root PTY access, failed handoff cleanup. Distinguish local foreground forwarding from shim-managed detached I/O. |
| 6. Docker experimental support | Register the binary through Docker's existing runc shim; run the [Docker acceptance matrix](docker-integration.md#acceptance-gates). Fill Docker-generated bundle gaps found by evidence. | Rootful Docker run/exec with pipes and TTY, default bridge networking, volumes, limits, stats, pause/resume, stop/kill/rm, default security, and error cleanup on the declared cgroup driver. Publish the exact tested configuration and remaining exclusions. |
| 7. Broader kontainer functionality | User namespace mapping handshake, mapping-helper fallback and rootless operation/delegation; time namespaces/offsets; no-pivot; recursive attributes and idmapped mounts; domainname, sysctls, loopback and interface movement/rename; remaining process settings and resource controls listed below. | Feature-specific kernel probes plus init/exec/lifecycle cases; rootless tests run as an unprivileged host user. Test missing kernel/controller support explicitly. |
| 8. Distribution and scope closure | arm64 and x86_64 Linux execution, real musl/static build and execution, documented install and upgrade procedure. Close every implemented-target row with evidence or a named, agreed exclusion. | Debug/release Linux gates, engine matrix and architecture/libc matrix. A static claim needs an executable inspected and run without its build environment. |

Milestones 4 and 5 are independent feature tracks after the core launch contracts
are stable; both gate the ordinary Docker milestone. Rootless and advanced mounts
can proceed earlier if a concrete workload needs them. Full kontainer breadth is
not a prerequisite for the first constrained containerd experiment.

## Scope remaining after the first Docker milestone

The following still belongs to the kontainer-level goal even when a simple Docker
container works:

- Namespace maps and rootless operation; cgroup/time namespace combinations and
  time offsets; idmapped and recursive mount semantics; no-pivot setup.
- Process HOME lookup, omitted/empty process handling, scheduler, I/O priority,
  exec CPU affinity and NUMA memory policy; complete init/exec policy coverage.
- Hugepage limits, unified cgroup v2 settings, block I/O weight/throttling, device
  rules and corresponding update support; `exec --cgroup` and owned hierarchy cleanup.
- Seccomp notification listener handoff, socket activation (`LISTEN_FDS`), and
  sealed executable handoff. Existing unlanded drafts are reference material,
  not completed features or prescribed implementations.
- Remaining target options and availability/error paths in [the inventory](parity.md).

Cgroup v1, checkpoint/restore and systemd-managed cgroups are outside the pinned
target's implemented functionality. Legacy memory fields, CPU realtime controls,
network/RDMA resource classes and `blockIO.leafWeight` are also not target gaps:
the pinned target does not apply them. Do not import the entire runc backlog.
If Docker's chosen cgroup driver requires systemd integration, treat that as a
separate Docker-driven extension and make the scope decision explicitly.

## How to decide an increment is done

1. Define an observable workload and check the target's applying code, not just
   its schema, help text or selected upstream test names.
2. Add typed Swift plans and small resource-owning operations within the current
   boundaries. Preserve launch ordering and failure cleanup.
3. Use unit tests for parsing/planning and focused Linux integrations for actual
   kernel effects. Compare security and consumer contracts; accept documented
   formatting/diagnostic differences that do not affect supported callers.
4. Launch changes need the full Linux debug/release gate:
   `sh scripts/test-linux.sh --configuration all`. Engine integration additionally
   needs real containerd/Docker evidence; the current suite does not supply it.
5. Record toolchain, kernel, architecture, cgroup driver, security availability,
   reference versions and skipped cases. Keep implementation, old evidence and
   newly passing execution results distinguishable. Commit each meaningful change.

Next implementation slice: milestone 1's invocation/bundle capture and logging
contract, followed by milestone 2's bind mounts and supplied network-namespace
join. These remove concrete engine blockers while keeping changes reviewable.
