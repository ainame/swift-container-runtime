# swift-container-runtime

An educational Linux container runtime written in Swift. Explore how namespaces,
root filesystems, process isolation, and cgroups fit together in a small OCI runtime.

**For learning and experimentation.** This is not a production runtime or a security
boundary. Foreground terminals are not implemented; detached terminals are handed to
`--console-socket`. An unprivileged user can run [rootless containers](docs/runtime-reference.md#rootless-operation)
without a delegated cgroup. Experimental Docker support (`--runtime swift`) passes an
acceptance gate on Ubuntu with both the cgroupfs and the systemd cgroup driver
(`--systemd-cgroup`, Docker's usual default); see
[Docker integration](docs/docker-integration.md). Rootless Docker daemons are
[not supported yet](docs/docker-integration.md#cgroup-drivers-and-rootless-setups),
independent of cgroup v1. The [roadmap](docs/roadmap.md) targets
kontainer-runtime-level functionality and eventual Docker integration.

## Try it

Requires Swift 6.4 (6.4.1 on Linux), root, and Linux 5.11+ with cgroup v2 and
permission to create namespaces and mounts. Use a disposable Linux VM for experiments.
Linux builds also require libseccomp development headers (`libseccomp-dev` on
Debian/Ubuntu); the executable links the host libseccomp shared library.
OCI launch creates a session keyring by default; `--no-new-keyring` explicitly
opts into inheriting the caller's session if that is required.
macOS 27+ supports building and unit tests; running containers requires Linux.

```sh
swift build --product srunc
sudo .build/debug/srunc run --bundle /path/to/bundle mybox
```

A bundle contains `config.json` and a root filesystem. Start with the
[example configuration](docs/runtime-reference.md#example-bundle) for a static
BusyBox rootfs. Default `runc spec` output needs editing because this runtime
supports only a subset of OCI configuration; unsupported fields are rejected.

`run` waits for the workload, returns its exit status, and removes container state.
Use `--detach` to return after startup or `--keep` to retain stopped state.
For command options:

```sh
.build/debug/srunc --help
.build/debug/srunc run --help
```

## OCI validation

Every CI run checks srunc against the unmodified upstream
[OCI runtime-tools](https://github.com/opencontainers/runtime-tools) validation
suite, pinned to a fixed commit. The latest run on Ubuntu 26.04, x86_64, passes
35 of its 58 executables, with none failing. The other 23 are excluded by name,
each with a recorded reason:

- 16 test cgroup v1, while srunc supports only cgroup v2.
- 6 are upstream test defects or invalid inputs that runc 1.4.0 and v1.5.2 also fail.
- 1 needs SELinux, which the CI host lacks; AppArmor is loaded and its test runs.

This is not a claim of full conformance. The exclusions live in
[`scripts/runtime-tools-exclusions.json`](scripts/runtime-tools-exclusions.json),
`--strict` runs everything, and each CI run uploads raw TAP and results.
See [OCI runtime-tools validation](docs/testing.md#oci-runtime-tools-validation)
for how to run it, and [current status](docs/testing.md#current-runtime-tools-status)
for what the exclusions rest on and what is still unverified.

## What works

- Container lifecycle: create, start, run, exec, inspect, signal, and delete.
- Namespaces, a separate root filesystem, bind mounts and proc/tmpfs/devpts/sysfs/mqueue;
  read-only roots and path controls, credentials, capabilities, and resource limits.
- cgroup v2 memory, pids, CPU, cpuset and device controls; pause/resume, updates,
  process listing, statistics, and OOM events.

The `namespace-run` command offers a smaller experiment without an OCI bundle
or separate root filesystem:

```sh
sudo .build/debug/srunc namespace-run --hostname swiftbox -- /bin/sh -c 'hostname; echo $$'
```

It prints `swiftbox` and `1`: the command runs in new UTS, PID, and mount namespaces.

## Development

```sh
swift test
```

On macOS with Apple's `container` installed, run affected Linux debug suites:

```sh
container system start
sh scripts/test-linux.sh lifecycle oci
```

This runs debug unit tests and the selected integrations with Swift 6.4.1.
Choose suites for the change; reserve `--configuration all` for the full
debug/release review gate. See [validation tiers](docs/testing.md#validation-tiers).
Strict memory safety and warnings-as-errors remain enabled.

- [Runtime reference](docs/runtime-reference.md): command behavior, supported OCI fields, and launch design.
- [Development and testing](docs/testing.md): Linux setup, focused checks, and integration coverage.
- [Code organization](docs/code-organization.md): source layout and contributor conventions.
- [Scope and limitations](docs/parity.md): supported behavior and remaining differences.
- [Roadmap](docs/roadmap.md): ordered feature milestones after the Swift refactor.
- [Docker integration gap](docs/docker-integration.md): required contracts and acceptance gates.

## License and credits

[MIT](LICENSE). [runc](https://github.com/opencontainers/runc) is the behavioral
reference for OCI semantics; [kontainer-runtime](https://github.com/ternbusty/kontainer-runtime) is
the companion implementation and initial feature target. Both use Apache 2.0;
see [NOTICE](NOTICE) and [upstream licenses](LICENSES).
