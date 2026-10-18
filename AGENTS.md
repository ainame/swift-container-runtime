# Repository guidance

- Educational Linux runtime; runc is the behavioral authority and kontainer-runtime is the comparison target. Full parity work is paused; see `docs/parity.md` before choosing work.
- Use Swift 6.4 (6.4.1 on Linux). Keep strict memory safety and warnings-as-errors enabled.
- Use swift-system and swift-argument-parser. Discuss new external dependencies first. Preserve conditional Musl/Glibc imports.
- Prefer Swift Concurrency over locks for shared state, but keep CLI launch and pre-fork setup synchronous and single-threaded. Never hold a lock across `await`; explain unavoidable locking.
- Add comments for logical chunks in longer methods.
- Validate changes appropriately; Linux runtime behavior needs Linux integration evidence, not just macOS tests or compilation.
- Commit each meaningful change. Version tags have no `v` prefix. Never use `swift-actions/setup-swift@v2`.
