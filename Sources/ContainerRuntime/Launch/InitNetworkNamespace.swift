import SystemPackage

/// The supplied `linux.namespaces` network path, pinned and type-checked in
/// the supervisor before fork. The CLI keeps its own namespace; only the
/// single-threaded launcher's prepare step enters this one, before it
/// unshares the remaining namespaces.
struct InitNetworkNamespace: ~Copyable {
    private let descriptor: OwnedFileDescriptor
    private let required: Bool

    /// Opens `path`, or holds nothing when the plan supplies no path.
    /// - Throws: `RuntimeError` when the path cannot be opened or is not a
    ///   network namespace.
    init(path: String?) throws {
        descriptor = try path.map(Self.open) ?? OwnedFileDescriptor()
        required = path != nil
    }

    private static func open(_ path: String) throws -> OwnedFileDescriptor {
        var descriptor = OwnedFileDescriptor()
        let type: Int32
        do {
            // Nonblocking, so a FIFO at the path cannot block bootstrap.
            // Magic links and bind-mounted nsfs files are both valid.
            descriptor = try Kernel.File.open(path, .readOnly, options: .nonBlocking)
            type = try descriptor.borrowDescriptor { descriptor throws(Errno) in try Kernel.Namespace.type(of: descriptor) }
        } catch {
            throw RuntimeError("open supplied network namespace \(path): \(error)")
        }
        guard type == OCIRunPlan.Namespace.network.cloneFlag else {
            throw RuntimeError("supplied namespace is not a network namespace: \(path)")
        }
        return descriptor
    }

    /// Whether the pinned namespace is the caller's own (host) network namespace.
    func isCallerNamespace() throws -> Bool {
        guard required else { return false }
        let own = try Kernel.File.status(atPath: "/proc/self/ns/net").identity
        return try descriptor.withDescriptor { try Kernel.File.status(of: $0).identity } == own
    }

    /// setns(2) into the pinned namespace; nil when none was supplied.
    /// Called only in the single-threaded launcher.
    func join() -> Errno? {
        guard required else { return nil }
        return descriptor.failure { descriptor in
            Errno.failure { () throws(Errno) in try Kernel.Namespace.enter(descriptor, .network) }
        }
    }
}
