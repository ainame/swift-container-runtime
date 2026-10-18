# Engine invocation and logging baseline

Captured on 2026-10-18. This is a **real containerd/runc capture**, followed by a
Swift failed-create check through the same shim. Swift cannot yet run this
engine-generated bundle. Docker was not run. Milestone 1 is still incomplete.

## Profile and provenance

- Apple `container` 0.9.0 disposable Linux guest, aarch64, kernel `6.12.28`.
- Guest image `swift:6.4.1`, index digest
  `sha256:870edbd7f37b77dc01ebab7eb4e0475d16be82796a06734d0bdc010cd24ea32f`;
  Swift 6.4.1, Ubuntu 26.04. Swift uses the debug build, strict memory safety
  and warnings-as-errors. No release validation was performed for this slice.
- Ubuntu packages: `containerd 2.2.2-0ubuntu1.1`, `runc 1.4.0-0ubuntu1`,
  `busybox-static 1:1.37.0-7ubuntu1`. The installed shim's Go build metadata
  records **go-runc v1.1.0**, rather than the local checkout's v1.2.1.
- Rootful, cgroup v2/cgroupfs, explicit `/sct-baseline` workload cgroup,
  nonterminal, fresh PID/IPC/UTS/mount/network namespaces. No user mappings,
  seccomp profile, AppArmor profile, SELinux label or hooks requested. This
  does not exercise default Docker security or bridge networking.
- Workload rootfs is a directory with `/bin/busybox`, not an image pulled by
  containerd. BusyBox SHA256:
  `c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02`.
  Shim SHA256: `1a0105ea166c89fed79e64001f2020941af3425cac3d5f8861a708e44a9c6a06`;
  runc SHA256: `b30dde4b6df96a676fb089251a8be8b5b32cef1c210fc637f28e009fec2dfb8e`.

The [capture directory](engine-baseline/) contains argv arrays and create/exec JSON
copied at the runtime boundary by [the tracing wrapper](../scripts/capture-engine-runtime.py).
The committed JSON is pretty-printed; values and original ephemeral paths are
preserved. No environment secrets were supplied or found in these bundles.
`exec-2` is the failing `/missing-program` exec. `delete-2 --force` is the shim's
cleanup invocation after the explicit task deletion. File ordering within each
JSON object is not evidence of setup ordering.

## Reproduction

Use a disposable rootful Linux guest with the package versions above, Python 3
for the tracing wrapper, and the repository mounted at `/workspace`. The wrapper
replaces itself with runc using unchanged arguments. Its optional environment
settings must be inherited by the daemon, not just the `ctr` client.

```sh
# In a fresh guest whose cgroup root has type "domain":
mkdir /sys/fs/cgroup/runner
echo $$ > /sys/fs/cgroup/runner/cgroup.procs
# In this guest PID 1 is our own `sleep infinity`; move it too.
echo 1 > /sys/fs/cgroup/runner/cgroup.procs
echo '+memory +pids +cpu +cpuset' > /sys/fs/cgroup/cgroup.subtree_control
mkdir -p /tmp/sct-engine/rootfs/bin
cp /bin/busybox /tmp/sct-engine/rootfs/bin/busybox
cp /workspace/scripts/capture-engine-runtime.py /tmp/capture-runtime
chmod +x /tmp/capture-runtime
containerd --root /tmp/sct-engine/root --state /tmp/sct-engine/state \
  --address /tmp/sct-engine/containerd.sock > /tmp/sct-engine/daemon.log 2>&1 &
# Wait for `ctr --address /tmp/sct-engine/containerd.sock version` to succeed.
ctr --address /tmp/sct-engine/containerd.sock run --rootfs \
  --runc-binary /tmp/capture-runtime --cgroup /sct-baseline -d \
  /tmp/sct-engine/rootfs baseline /bin/busybox sleep 900
ctr --address /tmp/sct-engine/containerd.sock tasks exec --exec-id extra -d \
  baseline /bin/busybox sleep 300
# Expected failure, captured as exec-2:
ctr --address /tmp/sct-engine/containerd.sock tasks exec --exec-id bad \
  baseline /missing-program
ctr --address /tmp/sct-engine/containerd.sock tasks kill --signal SIGKILL --all baseline
ctr --address /tmp/sct-engine/containerd.sock tasks rm baseline
ctr --address /tmp/sct-engine/containerd.sock containers delete baseline
```

The first guest, started with explicit Apple CPU/memory limits, exposed a
`domain threaded` cgroup root; runc failed cgroup creation there. The successful
capture used a fresh guest without those explicit limits, with a `domain` root
and the delegation above. Do not diagnose that host-profile failure as a Swift
or containerd argv failure. No daemon default runtime was changed.

## Applying source contract

The inspected local repositories include the exact tags for the installed
consumer, as well as the newer checkouts used in the planning assessment:

- [containerd v2.2.2 (`116b799`) init.go](https://github.com/containerd/containerd/blob/116b799b27bcb69462e26db2d70c4823211befeb/cmd/containerd-shim-runc-v2/process/init.go):
  `NewRunc` sets root, bundle `log.json` and JSON format; `Create` supplies PID
  file and optional no-pivot/no-new-keyring. `exec.go` requests detached exec,
  process JSON and a separate PID file.
- [containerd v2.2.2 utils.go](https://github.com/containerd/containerd/blob/116b799b27bcb69462e26db2d70c4823211befeb/cmd/containerd-shim-runc-v2/process/utils.go):
  `getLastRuntimeError` decodes a JSON stream into `Level`, `Msg`, `Time time.Time`,
  and returns the last trimmed error message. Time must therefore parse as RFC3339.
- [go-runc v1.1.0 (`79de646`) runc.go](https://github.com/containerd/go-runc/blob/79de646676291640496a1f510ce6bbecb1b8e1ba/runc.go):
  `args`, `CreateOpts.args`, `ExecOpts.args`, `Create`, `Exec`, `Kill`, `Version`,
  `Features`. The inspected v1.2.1 checkout (`6836456`) retains this basic
  contract, adding per-exec log override support. Capture conclusions apply to
  the installed version; they do not establish every newer consumer path.

## Result and remaining blockers

Global `--log PATH`, `--log-format text|json`, and `--debug` are implemented.
The log opens for append before execution, is close-on-exec, and uses no shared
mutable logger or threads. Runtime failures produce one error record; debug adds
command diagnostics without argv or bundle secrets. JSON command output stays on
stdout, and errors remain available on stderr. Workload exit codes are not logged
as runtime failures. Missing caller FDs are checked before opening the log.
ArgumentParser failures also reach the log when the engine's valid global prefix
precedes the command. Invalid logging options themselves and help/version exits
retain parser diagnostics; parse-error recovery does not scan workload operands.
Internal lifecycle warnings retain their existing stderr behavior.

The same `ctr run` command using the Swift Linux binary, ID `swift-baseline` and
cgroup `/sct-swift-baseline` returned:

```text
ctr: failed to create shim task: OCI runtime create failed: config.json: unsupported field(s): linux.resources.devices
```

This proves the real shim accepts the global options and extracts the Swift error
log. The reference runc workload and detached exec succeeded; its missing-program
exec returned the expected OCI exec failure. After kill/delete, containerd listed
no tasks or containers. Both runtime state directories and workload cgroups were
absent after reference cleanup and the Swift failed create. No Swift workload
was launched through the shim, so Swift shim-owned exit/reaping/stdio behavior
remains unverified.

| Immediate contract | Status after this slice |
| --- | --- |
| Global logging and error extraction | Implemented; real shim failed-create evidence above. |
| Captured create JSON | First rejection is `linux.resources.devices`. The requested mqueue/sysfs mounts now have focused Linux coverage below. Security restrictions must be implemented or explicitly rejected, never dropped to get past decoding. |
| Captured exec JSON | Decodes and validates as a Swift process plan; actual shim exec into Swift is blocked by create. |
| `kill --all` | Implemented with runc 1.4 compatibility semantics; see the focused kill validation below. |
| Version/features | Focused metadata integration passes. go-runc v1.1.0's version parser only populates values for the literal `runc version ` prefix; Swift retains its own identity, so this helper returns empty metadata. The captured shim create path did not query version. Features emit valid OCI JSON; broader engine feature negotiation is unverified. |
| Optional flags | Source: no-pivot/no-new-keyring appear only when requested; neither occurred in this capture. Swift still rejects them explicitly. Keyring setup and no-pivot remain deferred. `--systemd-cgroup` and explicit global `--rootless` remain rejected; no systemd support is implied. |
| Next runnable scenario | Implement requested mounts and device policy, then supplied namespace paths/bind mounts for richer bundles. Continue with a declared cgroupfs nonterminal scenario; retain remaining milestone-1 PID-publication and cleanup gates. |

## Focused validation

- macOS Swift 6.4 and Linux Swift 6.4.1: 44 CLI tests passed, then the added
  captured-argv test (six cases) and two captured-JSON tests passed.
- Linux debug: `logging`, `metadata`, `oci`, `lifecycle` integration suites passed
  against installed runc where applicable. This includes direct launch failures,
  PID publication, subreaper cases, exit status, descriptor and state cleanup.
- Linux debug: `preserve-fds` passed with a wrapper enabling JSON file logging for
  every Swift invocation, covering init/exec in foreground and detached modes.
- The logging suite checks append, JSON timestamps/error selection, failed
  create/start/exec, parse errors, stdout separation, text logs, early log-open
  failure, and caller-descriptor validation. Its missing-bundle/state cases are
  synthetic failure probes, distinct from the live engine capture above.
- No full unit suite, release matrix, Docker, terminal, rootless or second
  architecture gate was run. Those are not claims of this implementation slice.

## Follow-up: shim kill compatibility

`kill --all` / `-a` now parses the captured shim invocation. Following the
installed runc 1.4 applying code (`Container.signal` in
`libcontainer/container_linux.go`, `signalAllProcesses` in `init_linux.go`),
SIGKILL kills the cgroup subtree for a shared PID namespace, including surviving
processes after init exits. Private PID namespaces retain init-pidfd signaling
and kernel descendant teardown. Other signals still target init, even with
`--all`; the compatibility flag also succeeds for an already-stopped container.
A missing container remains an error. Plain kill of a stopped empty container
retains Swift's stricter stopped-state diagnosis.

The cgroup-wide operation writes `cgroup.kill` through the recorded boot/inode
identity and a pinned directory. It requires Linux 5.14+ and never falls back to
unverified PID enumeration or the current object at a replaced path. It does not
remove state or the cgroup; delete remains responsible for cleanup.

Fresh checks on the same Linux profile: 46 CLI tests, the new `kill` integration
suite, `logging`, and the lifecycle regression suite passed. The kill suite runs
under a real subreaper and compares Swift with installed runc: private/shared PID
namespaces, stopped init with surviving children, descendant cgroups, paused
cleanup, non-KILL init-only signaling, missing/stopped compatibility, reaped
processes, and a separate bystander cgroup. A Swift-only stale-boot case proves
that invalid cgroup identity cannot signal live members. The fixture explicitly
thaws runc's empty frozen group before deleting it; Swift already thaws on kill.
No Swift engine workload succeeds yet: device policy and mounts still block the
captured create, and shim-owned PID publication/exit cleanup still needs engine
execution evidence.

## Follow-up: requested filesystem mounts

The mount planner now accepts sysfs and mqueue, alongside existing tmpfs-based
shm, and `ro`/`rw` options (last requested mode wins). The existing setup applies
these using pinned destination directories in the new mount namespace. No new
external dependency, mount-path resolver, syscall or launch-order change was
needed. Bind mounts, cgroup mounts and supplied namespace paths remain open.

Fresh evidence on the same Linux profile: 179 runtime unit tests passed; the
new `filesystems` suite, OCI, readonly-root and metadata debug integrations
passed against installed runc. The filesystem probe verifies sysfs/read-only
flags and EROFS, sysfs's new network namespace view (only lo), tmpfs shm, actual
queue send/receive in a private IPC namespace, and the same host queue surviving.
Create-time mount tables and later init/exec results agree. A symlinked sysfs
destination after earlier mounts fails run/create without a workload, state,
cgroup or host mount/content change. Targeted macOS planning and CLI tests pass.

A unit-only projection of the captured create JSON, removing device rules to
isolate mount planning, now builds a plan. It is explicitly synthetic and is not
engine execution evidence. The unchanged original captured bundle still rejects
`linux.resources.devices`; no security field is discarded by the runtime, and
no successful Swift engine workload is claimed.
