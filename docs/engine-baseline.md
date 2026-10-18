# Engine invocation and logging baseline

Captured on 2026-10-18. This began with a **real containerd/runc capture** and a
Swift failed-create logging check. The device-policy follow-up at `6344146` now
passes a constrained Swift containerd directory-rootfs scenario through the same
shim. The bind follow-up at `62f04f2` also passes a pinned Alpine image with the
native snapshotter. The network follow-up at `1226be9` also joins a supplied
network namespace and reaches its private TCP listener through image exec.
The seccomp follow-up at `1e1673b` passes containerd default/custom syscall
profiles on the pinned image. See the final sections for evidence and exclusions.
The keyring follow-up at `761c9f6` also verifies image init/exec session identity
and shared keys. Docker was not run; broader namespace/security/console gates
remain open.

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
| Optional flags | Source: no-pivot/no-new-keyring appear only when requested; neither occurred in this capture. The later keyring follow-up implements no-new-keyring; no-pivot remains deferred. `--systemd-cgroup` and explicit global `--rootless` remain rejected; no systemd support is implied. |
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

## Supplied network namespace follow-up

Implementation `1226be9`, checked in the same rootful arm64 Linux debug guest,
containerd 2.2.2/runc 1.4.0 and pinned Alpine image described above. The preceding
bind checkpoint used a fresh unconfigured network; this follow-up consumes an
externally prepared one. No security restrictions were removed from the image
bundle: its device policy and file/volume bind restrictions remain applied.

Only nonempty **absolute network paths** are supported. Both proc namespace
links and bind-mounted nsfs files are pinned and type-checked before fork. The
launcher joins before creating the remaining namespaces or mounting sysfs; the
supervisor stays in its original network. Empty/null paths keep create semantics.
Relative paths and joins for other namespace types are explicitly rejected.

Fresh verification:

- 191 Linux runtime unit tests passed during implementation; final focused
  namespace-planning tests and the captured-image test passed after the absolute
  path restriction and error assertions were finalized. The same final focused
  tests passed on macOS with Swift 6.4.
- `network-namespace` passes Swift and runc foreground/create/start/exec cases:
  proc links, bind-mounted nsfs paths, exact created-init namespace identity,
  private loopback TCP and exec after the original path is unmounted/removed.
  Caller isolation, workload descriptor closure and cgroup cleanup are checked.
- Swift failures for missing paths, ordinary files, FIFOs, wrong namespace type
  and missing setns privileges leave no running workload, state or cgroup, and
  preserve the caller and namespace owner. The FIFO check cannot block opening.
- Focused Linux debug `oci`, `lifecycle` and `preserve-fds` suites passed against
  runc after this change. No release/full-matrix validation was repeated.

The engine wrapper creates a private namespace, brings up its loopback interface,
and starts a TCP listener there. Containerd supplies `/proc/PID/ns/net` through
`ctr --with-ns`; the test checks init's namespace inode and uses image-backed
`ctr tasks exec` to receive `joined-network`. A connection from the caller's
network fails before and after. Existing image assertions also pass: readonly
config, writable volume, PID files, exec exit status, kill/delete, shim reaping,
and snapshot/state/cgroup cleanup. The wrapper then removes its listener.

```sh
ENGINE_CAPTURE_DIRECTORY=/workspace/docs/engine-baseline/image-network \
  sh scripts/containerd-network-integration.sh \
  .build/linux-6.4.1/debug/swift-container-runtime \
  /tmp/sct-engine/containerd.sock sct-image-baseline \
  docker.io/library/alpine@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0
```

[Captured result](engine-baseline/image-network/result.txt) and
[original create JSON](engine-baseline/image-network/create.config.json) preserve
the actual ephemeral path and bundle values (JSON formatting only changed).
The public image supplied PATH only; no environment secrets were found.
This proves supplied namespace consumption with private loopback I/O. It does not
verify Docker, bridge/NAT/DNS provisioning, cgroup/other supplied namespace types,
rootless operation, requested seccomp/LSM/hooks, TTYs or another architecture.

## Seccomp follow-up

Implementation `1e1673b` adds a Linux-only dynamic libseccomp binding, strict OCI
policy decoding, parent-side BPF export and child-side loading for init and every
exec. Linux builds now need `libseccomp-dev`; this guest has **2.6.0-2ubuntu5**
(headers and runtime library). `ldd` confirms the Swift executable resolves
`libseccomp.so.2` from `/usr/lib/aarch64-linux-gnu`. macOS still builds without it.
Static/musl packaging is not established by this dynamic build.

Source ordering was checked against local runc `b1281089d47f53cd019804c1d9dfb1d5164d9aa7`
(`standard_init_linux.go`, `setns_init_linux.go`, `seccomp/seccomp_linux.go`) and
kontainer `357b8f295a7fad450c822c61e79cf22f75546640` (seccomp implementation and
build configuration). The **executed reference** remains installed runc
1.4.0-0ubuntu1, not a rebuild of that checkout. Kontainer's default dynamic system
library approach is used here; its optional pinned-source/static build is not.
Native architecture retention and duplicate-argument OR behavior follow runc.

Fresh checks in the same arm64/kernel/rootful cgroupfs guest:

- All Linux unit targets passed, including **197 runtime tests**. Final focused
  policy/metadata/fixture tests passed after the load-result guard change.
  Focused macOS checks passed with Swift 6.4, including the Kernel import boundary.
- `seccomp` passes against runc: UID 0/1000 with no_new_privs true/false;
  foreground run and create/start; created-init filter mode; direct getpgid/EACCES
  in init and exec; exec after an edited bundle and standalone process exec after
  bundle removal; no state/cgroup leaks. Seccomp is stored in runtime state and
  cannot be replaced by rereading a modified bundle.
- All seven comparisons pass allowed and denied direct-syscall probes, including
  a value above 32 bits, distinct-index AND and repeated-index OR. LOG allows,
  TRACE without a tracer returns ENOSYS, and TRAP/KILL/KILL_THREAD/KILL_PROCESS
  terminate with SIGSYS under both runtimes. Explicit []/TSYNC/LOG/SPEC_ALLOW
  flags load successfully in Swift.
- An inherited filter refusing SECCOMP_SET_MODE_FILTER causes the child to
  report a load failure, without a workload, state or cgroup. Unsupported
  notification policies/flags and unknown syscall names also fail cleanly.
- Debug OCI, lifecycle, credentials, capabilities and preserve-fds regressions
  passed against runc after the setup changes. The metadata integration also
  passes after updating its old disabled-seccomp assertion; it still requires
  AppArmor/SELinux/idmapped mounts to report disabled. No release/full-matrix
  validation was repeated for this increment.

The direct no_new_privs-false cases use getpgid rather than getcwd: installed
runc itself needs getcwd during its post-load setup and rejects an early getcwd
deny policy. The engine getcwd profile below uses no_new_privs true and tests
actual exec denial, rather than claiming runtime bootstrap overhead parity.

The [reference default bundle](engine-baseline/seccomp-reference/default.config.json)
and [custom getcwd bundle](engine-baseline/seccomp-reference/deny-getcwd.config.json)
were captured from actual containerd/runc runs using
`scripts/containerd-seccomp-capture.sh`. The default profile supplies ARM and
AArch64 architecture tokens and 12 rules with ERRNO/ALLOW actions, socket NE,
personality EQ and clone MASKED_EQ comparisons. These are unmodified engine
values, not a manually reduced profile. [Reference output](engine-baseline/seccomp-reference/result.txt)
records filter mode 2 and allowed getcwd with the default profile, followed by
getcwd/EACCES under the custom one.

The same image/native-snapshotter scenario then passes through Swift with
containerd's `--seccomp` default and custom `--seccomp-profile`:

```sh
ENGINE_CAPTURE_DIRECTORY=/workspace/docs/engine-baseline/image-seccomp \
  sh scripts/containerd-seccomp-integration.sh \
  .build/linux-6.4.1/debug/swift-container-runtime \
  /tmp/sct-engine/containerd.sock sct-image-baseline \
  docker.io/library/alpine@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0
```

[Swift result](engine-baseline/image-seccomp/result.txt),
[default create JSON](engine-baseline/image-seccomp/default/create.config.json),
and [custom create JSON](engine-baseline/image-seccomp/deny-getcwd/create.config.json)
record init filter mode and the direct exec syscall result. Both retain enforced
device rules, readonly configuration and probe binds, writable volume I/O, PID
publication, detached exec, exit 42, kill/delete, reaping and snapshot/state/cgroup
cleanup. Captured JSON is pretty-printed with values unchanged; all captured
process environments contain only the public image PATH, with no secrets found.

This establishes containerd default-profile execution and explicit custom syscall
enforcement on native arm64. It does not establish Docker defaults, 32-bit ABI
execution, another architecture, seccomp notification, requested LSM/hooks,
OOM adjustment, session-keyring isolation, TTYs or bridge/DNS. Unknown syscall
names are rejected rather than ignored as in runc, and unknown/future syscall
numbers get the configured default action rather than runc's ENOSYS fixup.
See [runtime reference](runtime-reference.md#seccomp-policy) for the supported
policy and setup/bootstrap constraints. The broader roadmap remains active.

## OOM score adjustment follow-up

Implementation `01a74f5`, checked in the same rootful arm64 Linux debug guest,
Swift 6.4.1, kernel 6.12.28 and installed runc 1.4.0-0ubuntu1. This is direct
runtime evidence for the new OCI process field; the preceding containerd image
captures did not request an OOM adjustment and do not establish that engine case.

`process.oomScoreAdj` accepts -1000...1000. Its decimal bytes are prepared before
fork and written only by the launcher, before namespace entry/creation, rootfs,
uid/capability changes, rlimits and seccomp. Descendants inherit the setting;
the original CLI and caller are unchanged. Absent/null makes no write, whereas
explicit 0 resets an inherited nonzero score. Failure to write is a launch error,
with no workload, state or cgroup left behind.

The original container setting is persisted for later exec, as in runc's
`container_linux.go` OomScoreAdj bootstrap attribute. Editing/removing the source
bundle or supplying an OOM value in a standalone exec process does not replace it.
When the original setting is absent, each exec inherits its own invoking process's
score, not the live init's score. Process-file values are validated even though
they do not override container policy.

Verification:

- All Linux unit targets passed, including **201 runtime tests**; focused OOM
  validation/state tests and configuration regressions also passed on macOS.
- [OOM suite output](engine-baseline/oom-adjustment/result.txt) compares foreground
  run, create-time procfs values, start and exec with runc, as UID 0 and UID 1000:
  absent/null, -1000, -321, 0, 321 and 1000; bundle edits/removal; ignored
  standalone-process overrides; unchanged init and caller; state/cgroup cleanup.
- A fixture-owned wrapper starts with score 275. Absent configuration preserves
  275; explicit 0 resets it. An unconfigured init remains at 275 while a new exec
  invoked at 350 receives 350. The original test caller remains unchanged.
- Dropping only CAP_SYS_RESOURCE refuses a negative write under both runtimes
  before namespace setup. Out-of-range values fail before the launcher is forked.
- Focused debug network-namespace, seccomp, OCI, lifecycle and preserve-fds
  regressions pass against runc. No release/full-matrix validation was repeated.

```sh
sh scripts/run-integration.sh .build/linux-6.4.1/debug/swift-container-runtime oom
```

This tests OOM score configuration, not deliberate OOM killing or changes to
memory-event semantics. Session keyrings, requested LSMs and console support
remain separate security/integration work. The current guest successfully creates
an anonymous session keyring, so subsequent keyring checks can use the real kernel
rather than relying on unavailable-kernel fallback alone.

## Session keyring follow-up

Implementation `761c9f6`, checked in the same rootful arm64 Linux debug guest,
Swift 6.4.1/kernel 6.12.28, containerd 2.2.2 and installed runc 1.4.0-0ubuntu1.
No runtime library dependency was added; Kernel wraps keyctl(2) directly.

New containers create/join `_ses.<id>` before rootfs/security setup, preserve
permissions while adding UID-owner search, and join the same session for later
exec without resetting permissions. The process performing the keyctl operations
is the init/exec child, not the supervisor. `--no-new-keyring` explicitly opts
init and exec into inheriting their own callers' sessions. That policy is recorded
before launch, survives bundle removal, and is independent of process-file JSON.
Records from before this feature keep inherited sessions on exec.

The names and permission ordering follow runc and the pinned kontainer source.
Names share runc's UID/user-namespace scope rather than runtime state-root scope;
identical IDs in different state roots can therefore join the same named session.
This is caller-session separation, not an unforgeable container identity or a
standalone security boundary. Requested LSM/key-creation labeling remains open.

Verification:

- All Linux unit targets passed, including **203 runtime tests**. Focused macOS
  tests cover preparation, opt-out, persistence and legacy record decoding.
- `keyring` passes direct Linux comparisons with runc as UID 0/1000: named init
  and exec IDs, exclusion of a real caller-session key, shared container keys,
  distinct sessions for another live container ID, foreground/detached/create/
  start, standalone exec after bundle removal, persistent opt-out and cleanup.
  A fixture-owned parent holds its session and verifies it stays unchanged.
- Swift-only probes deny JOIN_SESSION_KEYRING or SETPERM with EPERM/ENOSYS:
  create/run fail without a workload, state or cgroup. A failed exec join leaves
  init and its cgroup membership/session intact; legacy state and explicit opt-out
  retain inheritance. Unlike runc's best-effort join ENOSYS fallback, Swift fails
  unless opted out, so unavailable isolation is not silently treated as success.
- Focused debug OCI, lifecycle, credentials, capabilities, preserve-fds and metadata
  regressions pass. No release/full-matrix check was repeated for this increment.

The pinned Alpine image also passes the native-snapshotter/keyring gate through
the real shim. Init writes its session ID to the writable volume; an exec joins
that ID and adds a key, and a second exec joins it and reads the key. The gate
retains readonly file/probe binds, volume writes, PID files, detached exec, exit
42, kill/delete, shim reaping and snapshot/state/cgroup cleanup:

```sh
ENGINE_CAPTURE_DIRECTORY=/workspace/docs/engine-baseline/image-keyring \
  sh scripts/containerd-keyring-integration.sh \
  .build/linux-6.4.1/debug/swift-container-runtime \
  /tmp/sct-engine/containerd.sock sct-image-baseline \
  docker.io/library/alpine@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0
```

[Image result](engine-baseline/image-keyring/result.txt) and
[original create JSON](engine-baseline/image-keyring/create.config.json) are real
engine evidence. JSON is pretty-printed with values unchanged; the image supplied
PATH only, with no environment secrets found. This explicit diagnostic profile
permits keyctl and requests no seccomp profile. Separately, the existing
containerd default/custom seccomp image gate
[passes with keyring setup enabled](engine-baseline/image-keyring/seccomp-result.txt),
proving setup works before the default workload policy blocks keyctl. That gate
keeps the original default profile and active custom syscall-denial checks.

The broader Docker, requested LSM/key-label, console, rootless and architecture
acceptance gates remain open. Keyring garbage collection is managed by the kernel;
tests establish that owned processes/state/cgroups are removed, not an immediate
GC deadline for unreferenced keys.

## Requested AppArmor and SELinux labels

Implementation `f7398a2` applies `process.apparmorProfile` and
`process.selinuxLabel` for init and exec, sets the SELinux key-creation context
before the session-keyring join, and refuses a requested module the host does
not enable before launch (see [runtime reference](runtime-reference.md#apparmor-and-selinux-labels)).

**Profile A: the usual Apple `container` guest** (kernel 6.12.28, aarch64). AppArmor
is not active and SELinux is built in without a loaded policy (context `kernel`,
selinuxfs not mounted), so only availability behavior can be shown. The `lsm`
suite passes: empty labels run unchanged; requested AppArmor/SELinux labels fail
run/create (and an exec process label fails exec) without a workload, state or
cgroup, while the container and plain exec stay intact; a nonempty
`linux.mountLabel` is refused. runc also refuses the SELinux label. Focused
`keyring`, `metadata`, `oci` and `lifecycle` pass; Linux unit targets pass with
208 runtime tests.

**Profile B: AppArmor host.** A disposable Lima VM (vz) with the Ubuntu 26.04.1
arm64 cloud image, kernel `7.0.0-34-generic`, AppArmor parser 5.0.2 with the
module enabled, `runc 1.4.0-0ubuntu1`, `containerd 2.2.2`. The Swift binary is the
`f7398a2` debug build from the `swift:6.4.1` image with `--static-swift-stdlib`,
SHA256 `e5b97d16444cbf099bd45f417ff07e6324257f4b36a477cdc16738d0c256a732`; it
needs the host's glibc 2.43 and libseccomp2.

- [Direct gate](engine-baseline/apparmor-direct/result.txt)
  (`scripts/apparmor-integration.sh`) loads two throwaway profiles. Swift and runc
  both confine a root init and a non-root no_new_privs init (`sct-test (enforce)`,
  a denied read), leave an unprofiled workload unconfined, apply an exec
  process-file override, and fail create with an unknown profile without state.
- Differences, both deliberate: runc 1.4.0 does not persist the profile in its
  state, so a `--process` exec without a profile ran unconfined (`runc
  (unconfined)`), while Swift applies the recorded container profile. runc's
  command exec rereads an edited bundle; Swift keeps the recorded policy.
- [Engine gate](engine-baseline/image-apparmor/result.txt) through the real shim
  with containerd's generated default profile (`ctr run --apparmor-default-profile
  sct-default`) on the pinned Alpine image: init and an engine exec both report
  `sct-default (enforce)` under the engine's no_new_privs, capabilities, device
  rules, masked/readonly paths and binds, and the usual exec, exit-status, kill,
  delete and snapshot/state/cgroup cleanup checks pass. The
  [create JSON](engine-baseline/image-apparmor/create.config.json) is
  pretty-printed with values unchanged.

```sh
sudo sh scripts/apparmor-integration.sh BINARY
sudo ENGINE_CAPTURE_DIRECTORY=DIR sh scripts/containerd-apparmor-integration.sh \
  BINARY /run/containerd/containerd.sock sct-image-baseline \
  docker.io/library/alpine@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0
```

Not verified: positive SELinux application and key labeling (no SELinux-enforcing
host), AppArmor together with the seccomp default profile through the engine, a
Docker-generated `docker-default` profile, and release builds. The rest of the
Profile B suite matrix was not run there.
