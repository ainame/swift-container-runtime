# swift-container-runtime

An educational Linux container runtime written in Swift. Explore how namespaces,
root filesystems, process isolation, and cgroups fit together in a small OCI runtime.

**For learning and experimentation.** This is not a production runtime or a security
boundary. Seccomp, device-cgroup controls, user namespaces, rootless operation,
and terminals are not implemented. The [roadmap](docs/roadmap.md) targets
kontainer-runtime-level functionality and eventual Docker integration.

## Try it

Requires Swift 6.4 (6.4.1 on Linux), root, and Linux 5.11+ with cgroup v2 and
permission to create namespaces and mounts. Use a disposable Linux VM for experiments.
macOS 27+ supports building and unit tests; running containers requires Linux.

```sh
swift build
sudo .build/debug/swift-container-runtime run --bundle /path/to/bundle mybox
```

A bundle contains `config.json` and a root filesystem. Start with the
[example configuration](docs/runtime-reference.md#example-bundle) for a static
BusyBox rootfs. Default `runc spec` output needs editing because this runtime
supports only a subset of OCI configuration; unsupported fields are rejected.

`run` waits for the workload, returns its exit status, and removes container state.
Use `--detach` to return after startup or `--keep` to retain stopped state.
For command options:

```sh
.build/debug/swift-container-runtime --help
.build/debug/swift-container-runtime run --help
```

## What works

- Container lifecycle: create, start, run, exec, inspect, signal, and delete.
- Namespaces, a separate root filesystem, proc/tmpfs/devpts mounts, read-only
  roots and path controls, credentials, capabilities, and resource limits.
- cgroup v2 memory, pids, CPU and cpuset controls; pause/resume, updates,
  process listing, statistics, and OOM events.

The `namespace-run` command offers a smaller experiment without an OCI bundle
or separate root filesystem:

```sh
sudo .build/debug/swift-container-runtime namespace-run --hostname swiftbox -- /bin/sh -c 'hostname; echo $$'
```

It prints `swiftbox` and `1`: the command runs in new UTS, PID, and mount namespaces.

## Development

```sh
swift test
```

On macOS with Apple's `container` installed, run the complete Linux gate:

```sh
container system start
sh scripts/test-linux.sh --configuration all
```

This runs unit tests and integration suites in debug and release with Swift 6.4.1,
comparing runtime behavior against runc. Strict memory safety and warnings as
errors are enabled in the package.

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
