# Docker integration gap

Assessment date: 2026-10-18. **Not supported or verified yet.** The runtime has a
useful lifecycle core, but several independent gaps block normal engine-generated
bundles. Registering its path with Docker alone will not make it usable.
This assessment is source-based; no containerd or Docker workload was run for it.

## Integration route

Use this route first:

```text
Docker CLI → dockerd → containerd → containerd-shim-runc-v2
                                      ↓ runc CLI contract
                               swift-container-runtime
                                      ↓
                                Linux workload
```

Docker documents both custom containerd shims and runc-compatible replacement
binaries. Registering a replacement binary reuses the existing runc shim; a Swift
shim or Docker API implementation is not needed for this route. The runtime must
satisfy the shim's actual arguments, bundle fields, FD handling, lifecycle and
error contracts. See [Docker's alternative runtime documentation](https://docs.docker.com/engine/daemon/alternative-runtimes/)
and [daemon runtime configuration](https://docs.docker.com/reference/cli/dockerd/#configure-runtimes).

Docker/containerd retain image pulling, unpacking, snapshot/overlay rootfs
preparation, network provisioning, volume provisioning and supervision. Swift
consumes the prepared rootfs, mounts and namespace references. It does not need
an image registry client, an overlay storage driver, a bridge/IPAM implementation,
a Docker CLI replacement or CRI support to reach this goal. Joining an
engine-provided network namespace and applying supplied mounts remain essential.

The executable must be installed where the **Linux daemon** runs. A macOS build
cannot serve as its Linux OCI runtime. Prefer a disposable Linux VM with a known
Docker Engine configuration for the first experiment; Docker Desktop guest
installation/customization is a separate deployment task.

## Gap assessment

Ratings describe missing work and validation, not an estimate of elapsed time.
“Present” means an implementation exists; it does not certify shim compatibility.
The first target should be rootful Linux, cgroup v2 with cgroupfs management,
no user remapping, and an explicit host security profile.

| Contract | Current evidence | Gap and priority |
| --- | --- | --- |
| Launch/control lifecycle | create/start/state/delete, PID files, detached exec with process JSON, process identity protection, update, pause/resume and stats exist. Detached processes are designed to reparent to a caller's subreaper. | Moderate integration work: prove shim reaping, FIFO/stdin ownership and EOF, exit codes, concurrent exec/control, forced removal and failure cleanup. Check PID-file publication failures after launcher exit. |
| CLI and diagnostics | Global `--root`; command options cover much of go-runc's basic API. No global log/debug options. | Immediate blocker: the inspected shim always configures `--log` and `--log-format json`. Implement the log record contract used for error extraction; keep JSON command output clean. Audit optional `--no-new-keyring`, `--no-pivot`, `--rootless` and `--systemd-cgroup` against the chosen versions. |
| Engine-generated OCI JSON | Strict decoding accepts a deliberately narrow subset, including annotations. | Large: capture real create and exec JSON. Add applying support for requested fields such as namespace paths, devices, seccomp, hooks and process security settings. Null/empty/default objects from engine serializers need explicit tests; never silently drop requested restrictions. |
| Rootfs/mounts | proc/tmpfs/devpts, default devices, pivot_root, readonly root and path controls. | Large immediate blocker: file/directory bind mounts, sysfs, shm/mqueue/cgroup mounts, remount/propagation flags and safe in-root symlink resolution. Docker's supplied hosts/resolv.conf/hostname and volume mounts must work. Snapshotter rootfs preparation remains upstream. |
| Namespaces/network | New mount/pid/uts/ipc/network namespaces; exec joins the recorded init's namespaces. | Large immediate blocker: OCI `namespace.path` is rejected on create. Add external namespace joins and cgroup namespaces plus tested host/shared combinations. Default Docker networking needs the engine's network namespace, not an empty isolated namespace. |
| Security | Credentials, capabilities, rlimits, no-new-privileges and path controls exist. | Large gate for ordinary use: seccomp, device BPF rules, custom devices, OOM adjustment, session keyring and requested AppArmor/SELinux handling. A run with security disabled proves only that explicit profile. Hooks are also needed when an engine/integration supplies them. |
| Console | Nonterminal stdio and descriptor/pidfd handoff exist. | Large for interactive use: PTY allocation, controlling terminal, console master FD handoff and initial size. The shim owns attached I/O and resize after handoff; direct foreground CLI forwarding is a separate responsibility. |
| Cgroups/resources | v2 memory/pids/CPU/cpuset, updates, stats, freezer and identity-safe cleanup. | Moderate to large: integration with an engine-created hierarchy, device filtering, `kill --all`, I/O limits and owned ancestor cleanup. Current support does not include systemd cgroup management. Never interpret a systemd slice tuple as a filesystem path. |
| Packaging/portability | SwiftPM executable and Linux debug/release CI definition. | Moderate: release-mode daemon-host installation and runtime library requirements; execute on both arm64 and x86_64. Musl/static distribution remains unverified. A dynamic build can serve the first experiment if its libraries are installed. |

**Overall:** this is beyond a namespace demo, but still multiple substantial
feature increments away from ordinary Docker use. The strongest reusable pieces
are lifecycle, credentials and basic cgroups. The first failures are likely CLI
logging and strict OCI decoding, before the workload executes. Fixing those will
expose mount and namespace gaps; it will not by itself complete integration.
This is an inference from source inspection, not an observed Docker failure trace.

Kontainer already documents a `ctr --runc-binary` example using an Alpine image,
seccomp, read-only rootfs, UID/GID mappings and resource controls. Reproducing that
scenario is a useful later parity gate; it is broader than the proposed first
rootful containerd slice. Its example/CI definitions were inspected, not run here.

## Acceptance gates

Use pinned engine/containerd versions and image digests in a disposable Linux VM.
Capture actual argv, OCI create/exec JSON and errors at the runtime boundary,
redacting environment secrets before saving fixtures. Verify the selected Swift
binary was invoked; a workload accidentally using the default runc is not evidence.

1. **Contract capture:** observe runc under the intended engine versions, replay
   invocation shapes against Swift, and identify every rejected argument/field.
   Verify logging, version/features parsing and global-option positions. Avoid
   generalizing from containerd `main` to every installed Docker release.
2. **Constrained containerd:** use the existing shim and `ctr run --runc-binary`
   where supported by the pinned version. Nonterminal image workload, create/start,
   pipes/EOF, detached exec and PID files, nonzero exit, kill/delete and failing
   executable. Record every disabled security feature. Check the shim receives
   exit status and leaves no orphan processes, mounts, descriptors or cgroups.
3. **Constrained Docker:** register `swift`, use `docker run --runtime swift`, and
   prove a nonterminal workload, detached long-running container, exec and
   stop/removal under a documented cgroupfs profile. Explicitly disabled seccomp
   or LSM policy is a temporary experiment, not default-security acceptance.
4. **Ordinary rootful Docker:** run with the selected host's default security
   settings, default bridge networking and DNS, bind/named volumes, readonly root,
   non-root user, capabilities, no-new-privileges, memory/CPU/pids limits and
   updates, pause/unpause and stats. Test `run -it` and `exec -it`, terminal resize,
   stdin close, stop timeout and forced removal with descendants. Prove denied
   syscalls/device access and failure cleanup as well as successful workloads.
5. **Extended support:** add rootless/user-remap, other cgroup drivers, architectures
   and libc builds as separately named profiles with their own execution evidence.
   Full kontainer functionality and Docker support remain separate claims.

Do not change the daemon's default runtime for these tests. A systemd-managed
host is not automatically covered by a cgroupfs-only result. Either document and
verify a suitable cgroupfs test configuration or implement systemd support as a
separate extension beyond kontainer's pinned functionality.

## Future registration example

This is the intended configuration shape **after the gates pass**, not a working
installation recipe for today's binary. Merge the entry into the test daemon's
existing configuration and follow that engine version's reload/restart procedure:

```json
{
  "runtimes": {
    "swift": {
      "path": "/usr/local/bin/swift-container-runtime"
    }
  }
}
```

Then select it explicitly:

```sh
docker run --rm --runtime swift hello-world
```

The small registration entry hides the work in the contracts above; it does not
supply missing OCI support, choose a cgroup driver, or disable security settings.

## Source baseline

These are reproducible inspection points, not a claim about the user's installed
engine version:

- Swift `8d21065`: `RuntimeCLI/RuntimeCommand.swift`, `ExecCommand.swift`,
  `Specification/OCIConfiguration.swift`, `OCIRunPlan.swift`, `Launch/ExecLaunch.swift`,
  `RootFilesystemSetup.swift`, `WorkloadSetup.swift`, `Lifecycle/ContainerLifecycle.swift`.
  Source paths are relative to `Sources/`.
- [kontainer `357b8f2` containerd example](https://github.com/ternbusty/kontainer-runtime/blob/357b8f295a7fad450c822c61e79cf22f75546640/docs/containerd.md).
- [containerd `954541e` shim init](https://github.com/containerd/containerd/blob/954541ee2d4073cd9a63b13afeddda8cd1a9a565/cmd/containerd-shim-runc-v2/process/init.go)
  (`NewRunc`, `Create`, kill-all) and
  [exec](https://github.com/containerd/containerd/blob/954541ee2d4073cd9a63b13afeddda8cd1a9a565/cmd/containerd-shim-runc-v2/process/exec.go)
  (detached exec, PID file, console/pipe setup).
- [go-runc `6836456`](https://github.com/containerd/go-runc/blob/68364566898bcedbf19ac5ff82acbca51546cbc3/runc.go):
  global argument construction, create/exec/kill/update, version and features.
  Also check the go-runc revision actually vendored by the selected containerd.
- [Docker runtime registration](https://docs.docker.com/engine/daemon/alternative-runtimes/):
  documented route through the existing shim. Docker-generated bundle details
  must still be captured from the pinned engine used for validation.
