# swift-container-runtime

An educational Linux container runtime in Swift. [runc](https://github.com/opencontainers/runc) is the behavioral reference; [kontainer-runtime](https://github.com/ternbusty/kontainer-runtime) is a companion implementation and the initial feature target.

The first iteration is a **namespace lab**. It creates new UTS, PID, and mount namespaces, makes mount propagation private, mounts `/proc` for the new PID namespace, and executes a command. It shares the surrounding Linux filesystem. It does not yet provide a container root filesystem, network isolation, resource limits, or a security boundary.

## Try the namespace lab

Requires Swift 6.2 or later and Linux with permission to create namespaces and mount procfs, normally root with the necessary capabilities.

```sh
swift build
sudo .build/debug/swift-container-runtime namespace-run --hostname swiftbox -- /bin/sh -c 'hostname; echo $$'
```

The executable after `--` must be an absolute path. Expected output:

```text
swiftbox
1
```

The command runs as PID 1, so normal Linux PID 1 signal behavior applies. The runtime waits for it and forwards its exit status. An outer container can restrict namespace or mount operations even when its user is root.

## Development on macOS

The command performs Linux kernel operations; macOS builds cannot run the namespace lab directly. Use a Linux VM or Apple's [`container`](https://github.com/apple/container) command to build and test the Linux executable.

The local development environment has Apple `container` 0.9.0 and a cached `swift:6.4` image. That installation has no `container machine` subcommand. A successful Swift build inside an Apple container checks Linux compilation; a namespace smoke test must separately demonstrate that its guest environment grants the required kernel capabilities.

## Design

- Swift handles argument validation and the host-side command interface.
- A small C launch shim performs namespace creation and child setup. Work after `fork` stays in C until `exec`, avoiding Swift runtime operations in the child of a potentially multithreaded process.
- Swift does not import `Glibc`. The shim uses Linux kernel APIs and ordinary C library interfaces, keeping a future musl build possible. musl has not yet been tested.
- There are no third-party package dependencies.

This starting point tests the process and interoperability assumptions before introducing OCI lifecycle management. See the [implementation roadmap](docs/roadmap.md) for the path toward kontainer-runtime feature parity.
