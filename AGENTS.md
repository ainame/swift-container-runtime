# Repository guidance

- Educational Linux runtime targeting kontainer-runtime-level functionality, with eventual Docker integration through the existing containerd runc shim. Use runc for OCI semantics and security ordering; exact parity with every runc behavior is not a goal. Follow `docs/roadmap.md`, `docs/parity.md`, and `docs/docker-integration.md` when choosing work.
- Use Swift 6.4 (6.4.1 on Linux). Keep strict memory safety and warnings-as-errors enabled.
- Use swift-system and swift-argument-parser. Discuss new external dependencies first. Preserve conditional Musl/Glibc imports, which belong only in `Sources/ContainerRuntime/Kernel/`; add new system calls there with an `ENOSYS` stub off Linux.
- Prefer Swift Concurrency over locks for shared state, but keep CLI launch and pre-fork setup synchronous and single-threaded. Never hold a lock across `await`; explain unavoidable locking.
- Add comments for logical chunks in longer methods.
- Validate changes appropriately; Linux runtime behavior needs Linux integration evidence, not just macOS tests or compilation.
- Commit each meaningful change. Version tags have no `v` prefix. Never use `swift-actions/setup-swift@v2`.
