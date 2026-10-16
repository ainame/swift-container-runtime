# swift-container-runtime

An educational Linux container runtime in Swift. [runc](https://github.com/opencontainers/runc) is the behavioral reference; [kontainer-runtime](https://github.com/ternbusty/kontainer-runtime) is a companion implementation and the initial feature target.

The first iteration is a **namespace lab**. It creates new UTS, PID, and mount namespaces, makes mount propagation private, mounts `/proc` for the new PID namespace, and executes a command. It shares the surrounding Linux filesystem. It does not yet provide a container root filesystem, network isolation, resource limits, or a security boundary.

## Try the namespace lab

Requires Swift 6.4 (Linux validation uses Swift 6.4.1) and Linux with permission to create namespaces and mount procfs, normally root with the necessary capabilities. The launcher currently requires Linux 5.3 or later for pidfds.

```sh
swift build
sudo .build/debug/swift-container-runtime namespace-run --hostname swiftbox -- /bin/sh -c 'hostname; echo $$'
```

The executable after `--` must be an absolute path. Expected output:

```text
swiftbox
1
```

The command runs as PID 1, so normal Linux PID 1 signal behavior applies. The runtime waits for it and forwards its exit status. For ordinary workloads retaining their parent-death signal setting, terminating the foreground runtime also terminates its launcher and namespace init. Credential changes, setuid/setgid or file-capability executables, and explicit changes to that signal setting can defeat this cleanup; stronger external supervision is a later milestone. Terminal relaying and graceful signal forwarding are not implemented yet. An outer container can restrict namespace or mount operations even when its user is root.

## Toolchain and checks

The package requires Swift tools 6.4. `.swift-version` selects the macOS 6.4.0 release without changing your global toolchain. Linux tests use the explicit `swift:6.4.1` image and a separate build directory. `Package.resolved` records the CLI dependency resolution.

```sh
swift test
```

Strict memory diagnostics and warnings-as-errors are package settings, so ordinary builds and tests enforce them automatically. GitHub Actions runs the unit tests and debug/release namespace checks in the pinned Swift 6.4.1 Linux image.

## Development on macOS

The command performs Linux kernel operations; macOS builds cannot run the namespace lab directly. Use a Linux VM or Apple's [`container`](https://github.com/apple/container) command to build and test the Linux executable.

Run the complete Linux build, unit tests, and privileged integration checks from macOS:

```sh
container system start
scripts/test-linux.sh
```

The script uses a disposable VM-backed `swift:6.4.1` container and stores Linux build products separately in `.build/linux-6.4.1`. It runs debug and optimized integration checks for namespaces, procfs, surrounding hostname/mount preservation, exit and signal status, argument handling, permission failures, and parent-death cleanup.

The local development environment has Apple `container` 0.9.0 and a cached `swift:6.4.1` image. That installation has no `container machine` subcommand. A successful Swift build inside an Apple container checks Linux compilation; a namespace smoke test must separately demonstrate that its guest environment grants the required kernel capabilities.

## Design

- Swift handles argument validation and the host-side command interface.
- A small C launch shim performs namespace creation and child setup. Work after `fork` stays in C until `exec`, avoiding Swift runtime operations in the child of a potentially multithreaded process.
- Swift does not import `Glibc`. The shim uses Linux kernel APIs and ordinary C library interfaces, keeping a future musl build possible. musl has not yet been tested.
- The CLI uses [swift-argument-parser](https://github.com/apple/swift-argument-parser), currently resolved to 1.8.2. It preserves workload arguments after the required `--` separator. Usage errors exit 64; setup failures exit 125; workload exit statuses pass through.
- Every project-owned Swift target enables `.strictMemorySafety()` and treats warnings as errors. This checks Swift source and its C call sites; it does not verify the C implementation.
- Argument bytes use Swift 6.4's `OutputSpan` initialization API in a single owned slab. A temporary `OutputSpan` owns the NUL-terminated pointer vector; its borrowed `Span` stays inside the C call. Audited `unsafe` expressions mark the raw-pointer boundary, with no manual Swift allocation/deallocation.

This starting point tests the process and interoperability assumptions before introducing OCI lifecycle management. See the [implementation roadmap](docs/roadmap.md) for the path toward kontainer-runtime feature parity.
