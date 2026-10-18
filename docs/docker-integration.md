# Docker integration gap

Assessment date: 2026-10-18. **Experimental Docker support is verified on one
declared profile:** rootful Docker 29.1.3 with containerd 2.2.2 and the cgroupfs
driver on an Ubuntu 26.04 arm64 VM (kernel 7.0, AppArmor enabled), registered as
an extra runtime and selected with `--runtime swift`. The [Docker gate](#current-result)
passes with Docker's default security there, as it does with runc. The CI `docker`
job runs the same gate and the AppArmor gate on GitHub's x86_64 Ubuntu 24.04
runner with its Docker switched to cgroupfs. Other hosts, the systemd cgroup
driver and rootless setups are unverified. The original
assessment was source-based; the [engine baseline](engine-baseline.md) records the
captures and execution evidence.

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
| Launch/control lifecycle | create/start/state/delete, PID files, detached exec with process JSON, process identity protection, update, pause/resume and stats exist. The constrained directory-rootfs shim test verifies PID publication/reaping, pipes/EOF, exit codes and failure cleanup. | Remaining integration work includes concurrent exec/control, richer image/namespace profiles, forced-removal variations and richer host profiles. Check PID-file publication failures after launcher exit. |
| CLI and diagnostics | Global `--root`; command options cover much of go-runc's basic API. Global log/debug options and text/JSON error logging are implemented. | The real containerd 2.2.2 shim extracts failed create/exec errors from Swift JSON logs. Captured create/exec bundles and argv are recorded in the engine baseline. `--no-new-keyring` now persists an explicit init/exec opt-out. Audit `--no-pivot`, `--rootless` and `--systemd-cgroup` against the chosen versions. |
| Engine-generated OCI JSON | Strict decoding accepts a deliberately narrow subset, including annotations. Directory-rootfs and pinned Alpine create/exec JSON now work through containerd. | Large for richer engine bundles: add applying support for requested fields such as non-network namespace paths, custom device entries, seccomp notification, hooks and process security settings. Null/empty/default objects from engine serializers need explicit tests; never silently drop requested restrictions. |
| Rootfs/mounts | proc/tmpfs/devpts/sysfs/mqueue, shm, read-only cgroup2 with a cgroup namespace, file/directory bind/rbind, ro/rw and explicit VFS flags, private/rprivate propagation, default devices, pivot_root, readonly root and path controls. Docker's hosts/resolv.conf/hostname binds, bind and named volumes and `--tmpfs` pass. | Remaining: broader propagation/remount flags, dangling target symlinks and protected-proc bind handling, a cgroup mount without a cgroup namespace. |
| Namespaces/network | New mount/pid/uts/ipc/network/cgroup namespaces; absolute supplied network paths join on create/run, and exec joins the live init. Docker's default bridge, published ports, container-to-container TCP, resolv.conf and namespaced sysctls pass. | Remaining: other namespace joins and broader host/shared combinations (for example `--network host`, `--ipc container:`). |
| Security | Credentials, capabilities, rlimits, no-new-privileges, path controls, OOM adjustment, named session keyrings, device BPF rules, non-notification seccomp and requested AppArmor/SELinux process and key labels exist; unavailable modules fail before launch. containerd's generated default AppArmor profile confines image init and exec on an Ubuntu AppArmor host. Containerd default/custom seccomp profiles pass the pinned image with active syscall-denial evidence. | Docker's default security (docker-default AppArmor, default seccomp, capabilities, device rules) passes the Docker gate. Remaining: custom devices, SELinux mount labels and positive SELinux evidence. A run with security disabled proves only that explicit profile. Hooks are also needed when an engine/integration supplies them. |
| Console | Nonterminal stdio, descriptor/pidfd handoff, and PTY allocation with controlling terminal, `/dev/console`, initial size and `--console-socket` master handoff for init and exec. containerd's shim attaches, resizes and reports exit status for `ctr run -t` and `ctr tasks exec -t`. Docker `run -it`/`exec -it` pass with the caller's size and exit status. | Remaining: the runtime's own foreground terminal proxy and later resize evidence. The shim owns attached I/O and resize after handoff; direct foreground CLI forwarding is a separate responsibility. |
| Cgroups/resources | v2 memory/pids/CPU/cpuset, updates, stats, freezer and identity-safe cleanup. | Moderate to large: integration with an engine-created hierarchy, I/O limits, live device-rule updates and owned ancestor cleanup. Shared-PID SIGKILL subtree cleanup and `--all` compatibility now have focused Linux evidence; the constrained nonterminal shim lifecycle passes, with broader image/profile acceptance still open. Current support does not include systemd cgroup management. Never interpret a systemd slice tuple as a filesystem path. |
| Packaging/portability | SwiftPM executable and Linux debug/release CI definition. | Moderate: release-mode daemon-host installation and runtime library requirements; execute on both arm64 and x86_64. Musl/static distribution remains unverified. A dynamic build can serve the first experiment if its libraries are installed. |

**Overall:** ordinary rootful Docker usage works on the declared profile, with
default security, networking, volumes, limits, terminals and cleanup. It is an
experimental claim for that one profile, not general Docker compatibility: a
systemd cgroup driver, rootless or user-remapped daemons, other architectures,
hooks supplied by plugins and non-network namespace sharing remain open.

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

During implementation use the [focused debug validation tiers](testing.md#validation-tiers).
At review, run the full debug/release runtime matrix once on the candidate and
run the engine scenarios needed for the claimed profile. A second architecture,
rootless setup or another engine version is a later profile, not a multiplier on
every implementation iteration. Hooks are required when supplied; completing all
six phases is not necessary for a hook-free first engine scenario.

## Current result

On the declared profile, `scripts/docker-integration.sh` passes for both `swift`
and Docker's default `runc` with the same pinned Alpine image; see the
[engine baseline](engine-baseline.md#docker) and
[results](engine-baseline/docker/result.txt). The gate checks the Swift runtime
actually created the container (its state format), then covers gates 3 and 4:
exit statuses including 127, default AppArmor/seccomp/capabilities with device
denial, bridge and published-port TCP, DNS configuration, volumes, read-only root,
non-root with dropped capabilities and no-new-privileges, memory/CPU/pids limits
and `docker update`, pause, stats, exec, `run -it`/`exec -it`, stop timeout and
forced removal without leaked processes or state. Denied seccomp syscalls are
covered by the containerd seccomp gate rather than this one.

## Registration

Merge the entry into the daemon's existing configuration, select the cgroupfs
driver this runtime manages, and follow that engine version's reload/restart
procedure. Keep runc as the default runtime:

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

The registration entry does not supply missing OCI support or change security
settings. The verified profile also sets `"exec-opts": ["native.cgroupdriver=cgroupfs"]`;
the Linux build needs the host's libseccomp2 (or a matching static build).

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
