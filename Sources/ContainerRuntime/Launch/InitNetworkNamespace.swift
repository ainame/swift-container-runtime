import SystemPackage

/// A single supplied namespace pinned before fork. The CLI keeps its own
/// namespace; only the single-threaded launcher's prepare step enters this one.
struct InitNetworkNamespace: ~Copyable {
    private let descriptor: OwnedFileDescriptor
    private let required: Bool

    init(path: String?) throws {
        descriptor = try Self.open(path)
        required = path != nil
    }

    private static func open(_ path: String?) throws -> OwnedFileDescriptor {
        guard let path else { return OwnedFileDescriptor() }
        do {
            // Nonblocking prevents a malformed FIFO path blocking bootstrap.
            // Namespace magic symlinks and bind-mounted nsfs paths are both valid.
            let descriptor = try Kernel.File.open(path, .readOnly, options: .nonBlocking)
            let type = try descriptor.borrowDescriptor { descriptor throws(Errno) in
                try Kernel.Namespace.type(of: descriptor)
            }
            guard type == OCIRunPlan.Namespace.network.cloneFlag else {
                throw RuntimeError("supplied namespace is not a network namespace: \(path)")
            }
            return descriptor
        } catch let error as RuntimeError {
            throw error
        } catch {
            throw RuntimeError("open supplied network namespace \(path): \(error)")
        }
    }

    func join() -> Errno? {
        guard required else { return nil }
        return descriptor.failure { descriptor in
            Errno.failure { () throws(Errno) in try Kernel.Namespace.enter(descriptor, .network) }
        }
    }
}
