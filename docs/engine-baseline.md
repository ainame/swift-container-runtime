# Engine invocation and logging baseline

Captured on 2026-10-18. This began with a **real containerd/runc capture** and a
Swift failed-create logging check. The device-policy follow-up at `6344146` now
passes a constrained Swift containerd directory-rootfs scenario through the same
shim. The bind follow-up at `62f04f2` also passes a pinned Alpine image with the
native snapshotter. See the final sections for evidence and exclusions. Docker
was not run; broader namespace/security/console gates remain open.

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

At the initial logging checkpoint (`bfe975e`), the same `ctr run` command using
the Swift Linux binary, ID `swift-baseline` and cgroup `/sct-swift-baseline` returned:

```text
ctr: failed to create shim task: OCI runtime create failed: config.json: unsupported field(s): linux.resources.devices
```

This proves the real shim accepts the global options and extracts the Swift error
log. The reference runc workload and detached exec succeeded; its missing-program
exec returned the expected OCI exec failure. After kill/delete, containerd listed
no tasks or containers. Both runtime state directories and workload cgroups were
absent after reference cleanup and the Swift failed create. At that checkpoint
no Swift workload had launched through the shim. The device-policy follow-up
below now verifies its constrained nonterminal exit/reaping/stdio behavior.

| Immediate contract | Status after this slice |
| --- | --- |
| Global logging and error extraction | Implemented; real shim failed-create evidence above. |
| Captured create JSON | Now plans its original device rules and filesystem mounts. The live constrained containerd run succeeds; no security field is dropped to get past decoding. |
| Captured exec JSON | Plans and executes through the real shim, including stdout, exit 42, detached PID publication and missing-program error extraction. |
| `kill --all` | Implemented with runc 1.4 compatibility semantics; see the focused kill validation below. |
| Version/features | Focused metadata integration passes. go-runc v1.1.0's version parser only populates values for the literal `runc version ` prefix; Swift retains its own identity, so this helper returns empty metadata. The captured shim create path did not query version. Features emit valid OCI JSON; broader engine feature negotiation is unverified. |
| Optional flags | Source: no-pivot/no-new-keyring appear only when requested; neither occurred in this capture. Swift still rejects them explicitly. Keyring setup and no-pivot remain deferred. `--systemd-cgroup` and explicit global `--rootless` remain rejected; no systemd support is implied. |
| Next runnable scenario | Supplied namespace joins, followed by remaining security/console gates. Directory-rootfs and pinned-image nonterminal scenarios now have live evidence below. |

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
At the kill checkpoint (`02dd277`), device policy still blocked create. The later
device-policy follow-up below supplies the first successful engine execution.

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

At the filesystem checkpoint (`bae681e`), a unit-only projection removed device
rules to isolate mount planning. That was synthetic, not live engine evidence.
The device-policy follow-up now plans the original unmodified captured fixture
and runs fresh engine-generated bundles without discarding their restrictions.

## Follow-up: device policy and first constrained containerd run

**Verified implementation revision: `6344146`**, Linux Swift 6.4.1 debug on the
same aarch64/kernel/package profile above. No new external dependency was added.
The applying reference is runc v1.4.0's
[spec conversion](https://github.com/opencontainers/runc/blob/v1.4.0/libcontainer/specconv/spec_linux.go),
[device emulator](https://github.com/opencontainers/runc/blob/v1.4.0/vendor/github.com/opencontainers/cgroups/devices/devices_emulator.go)
and [filter builder](https://github.com/opencontainers/runc/blob/v1.4.0/vendor/github.com/opencontainers/cgroups/devices/devicefilter.go).
The inspected emulator/filter files match those in the local newer checkout.

Nonempty `linux.resources.devices` is decoded strictly, normalized, then compiled
into a forward-only cgroup-device BPF program. Wildcard resets, permission merge
and standard-device ordering follow the reference. Kernel load/attach errors
fail setup before any init exists, with verifier diagnostics when available.
BPF `ALLOW_MULTI` preserves ancestor and externally attached filters. Cleanup
uses the owned program ID and verified cgroup inode/boot identity, including on
an adopted cgroup or a failed create. Live device-rule updates are explicitly
rejected; ordinary memory/pids/CPU updates retain the existing policy and filter.
Partial denies reject any overlapping access, including O_RDWR with a denied
read/write bit, which is stricter than runc 1.4's combined-access subset check.
Custom device inode declarations (`linux.devices`) remain unsupported.

Fresh verification:

- Linux: 184 runtime unit tests passed, then focused policy/fixture/metadata checks
  passed after the final small validation/help edits. Targeted macOS policy,
  resource-update, captured-fixture and CLI checks passed.
- Debug integrations `devices`, `cgroup`, `update`, and `lifecycle` passed.
  Device probes exercise successful standard-device opens, allowed versus denied
  custom-device opens, read/write masks, mknod, and init/exec policy. Their
  unallocated PTY slave returns ENXIO/EIO after an allowed custom open, versus
  EPERM from the filter when denied; successful `/dev/null` I/O is also checked.
- The device suite checks an adopted leaf with another program, failure cleanup,
  restrictive ancestor preservation, retained policy after resource updates,
  refused device patches, and fail-closed setup with BPF/SYS_ADMIN removed from
  bounding, inheritable and ambient capability sets. The partial-deny combined
  access case is Swift-only; shared profiles compare with installed runc.
- The explicit [containerd integration](../scripts/containerd-integration.sh)
  passed against the running 2.2.2 daemon using the Swift binary as `--runc-binary`.
  [Captured output](engine-baseline/containerd-success.txt) records this run.

```sh
sh scripts/containerd-integration.sh \
  .build/linux-6.4.1/debug/swift-container-runtime /tmp/sct-engine/containerd.sock
```

The script creates an isolated containerd namespace, runtime root and cgroup
subtree, and builds a directory rootfs from the pinned static BusyBox above.
It proves shim-owned init PID publication, stdout from exec, exec exit 42,
detached exec PID publication, missing-executable error extraction, SIGKILL-all,
reaped init/exec processes, closed shim FDs, state/cgroup removal, attached
stdin/stdout/stderr and EOF with exit 17, and failed-create cleanup. It does not
change a daemon default. The daemon's task list was empty after the runs.

Immediate stdin EOF before task setup hung under both Swift and runc in this
ctr version. Its source assigns the stdin-close callback only after NewTask;
that is a plausible early-close race, not a demonstrated Swift runtime defect.
The repeatable test holds its FIFO writer open until the task is RUNNING, then
sends input and closes it, proving actual EOF without a fixed startup delay.

This is **rootful cgroup v2/cgroupfs, UID 0, nonterminal, directory rootfs**, with
the engine's capability/rlimit/no-new-privileges and device policy applied. No
seccomp, requested LSM label, hooks, session-keyring isolation, user mapping,
bridge networking, image unpacking or TTY was tested. It is not ordinary Docker
support or completion of the image-derived containerd milestone. Bind mounts,
supplied namespace paths and cgroup mounts remain next; default security and
console support still gate Docker. Full release/debug matrices and another
architecture remain deferred to review/milestone validation.

## Follow-up: bind mounts and an image-backed engine scenario

**Verified implementation revision: `62f04f2`**, same Swift 6.4.1 debug/Linux
profile. File/directory bind and rbind mounts now pin their host sources before
mount setup, resolve existing target links in-root without magic links, create
missing target parents/files and use descriptor clone/attach operations. Relative
sources resolve from the bundle. A final bind at `/dev` disables automatic device
population, preventing writes into the host-backed source directory.

Bind attributes preserve inherited flags unless explicitly set/cleared. Supported
pairs are ro/rw, nosuid/suid, nodev/dev and noexec/exec, plus strictatime and
private/rprivate propagation. `rbind,ro` keeps child mount flags unchanged; it is
not recursive read-only. Explicit remount, other propagation modes, idmapping,
recursive attributes, dangling target links and direct bind destinations under `/proc` remain
unsupported. Attribute/propagation changes require Linux 5.12+.

Fresh checks:

- 186 Linux runtime unit tests passed before the final small `/dev` decision and
  fixture additions; focused planning/metadata/captured-image tests then passed
  on the final implementation. Targeted macOS planning and fixture checks pass.
- `bind` passes run/create/start/exec against installed runc: files, directories,
  recursive submount inclusion, readonly top mount with writable submounts,
  readonly-root behavior, explicit rw clearing a readonly source clone, atime,
  exec/nodev permissions, existing relative/absolute/climbing target links,
  relative sources, new targets and parent directories, private propagation,
  descriptor closure, unchanged host mount tables and failure cleanup.
- Source pinning under an earlier `/dev` mount is Swift-only: installed runc 1.4
  rejects that synthetic source after it is hidden. Preventing node creation in
  a host-backed `/dev` is also a Swift-specific regression. Unmentioned inherited
  security flags stay set here; runc 1.4 may clear them in its first remount
  attempt. These are documented differences, not a parity failure.
- OCI, lifecycle, readonly-root, path-controls and preserve-fds debug regressions
  passed. The directory-rootfs engine gate also passes actual engine-provided
  readonly file and writable volume binds.

The following image was fetched from Docker Hub and unpacked by containerd's
**native snapshotter**, then run using the Swift binary. The image's actual
`/etc/alpine-release` is **3.23.6**:

- Index/name: `docker.io/library/alpine@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0`.
- Selected Linux arm64/v8 manifest: `sha256:ae959799024a09da597284763c417a6e820e020fad0634c5267cf4f125e682bf`.
- Pull used `ctr images pull --local --snapshotter native --platform linux/arm64/v8
  docker.io/library/alpine:3.23`; the digest alias above was then stored locally
  and used for execution. The initial transfer-service pull failed with `no
  unpack platforms defined`; the explicit local/variant pull succeeded. That
  was an unpacker/client setup issue before the runtime was invoked.

```sh
ENGINE_CAPTURE_DIRECTORY=/workspace/docs/engine-baseline/image-bind \
  sh scripts/containerd-image-integration.sh \
  .build/linux-6.4.1/debug/swift-container-runtime \
  /tmp/sct-engine/containerd.sock sct-image-baseline \
  docker.io/library/alpine@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0
```

[Captured result](engine-baseline/image-bind/result.txt) and the
[original create JSON](engine-baseline/image-bind/create.config.json) are live
engine evidence, not a synthesized bundle. JSON is pretty-printed with values
unchanged; the public image supplied PATH only, with no environment secrets.
The original device rules remain applied. The image test proves readonly
`/etc/resolv.conf` contents and write refusal, volume writes reaching the host
source, init/exec, PID files, exec exit 42, kill/delete, reaping, and removal of
the native active snapshot, runtime state and cgroup. Cached image layers remain
in the explicitly selected namespace for later iterations.

This is still rootful cgroup v2/cgroupfs, UID 0 and nonterminal, with a fresh,
unconfigured network namespace. External namespace paths, bridge/DNS behavior,
TTYs, requested LSM/seccomp/hooks and session-keyring isolation remain unverified
or unimplemented as listed earlier. Native-snapshotter success does not certify
Docker's ordinary storage/network/security profile. No release/full-matrix or
second-architecture validation was repeated for this increment.
