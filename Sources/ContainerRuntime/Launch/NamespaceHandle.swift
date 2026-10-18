import SystemPackage

extension OCIRunPlan.Namespace {
    /// Linux procfs names differ from OCI for mount and network namespaces.
    var procName: String {
        switch self {
        case .mount: "mnt"
        case .network: "net"
        default: rawValue
        }
    }
}

/// A supplied namespace pinned and type-checked by the supervisor before fork.
/// The owning descriptor is close-on-exec; only the launcher calls setns. Skip
/// an already-current namespace, especially user namespaces where setns into
/// one's own namespace is forbidden by Linux.
final class NamespaceHandle {
    private let descriptor: OwnedFileDescriptor
    let namespace: OCIRunPlan.Namespace
    let matchesCaller: Bool

    init(path: String, namespace: OCIRunPlan.Namespace) throws {
        var opened = OwnedFileDescriptor()
        do {
            opened = try Kernel.File.open(path, .readOnly, options: .nonBlocking)
            let type = try opened.borrowDescriptor { descriptor throws(Errno) in try Kernel.Namespace.type(of: descriptor) }
            guard type == namespace.cloneFlag else {
                throw RuntimeError("supplied namespace is not a \(namespace.rawValue) namespace: \(path)")
            }
            let own = try "/proc/self/ns/\(namespace.procName)".withCString { path in try unsafe Kernel.File.status(atPath: path).identity }
            matchesCaller = try opened.borrowDescriptor { descriptor throws(Errno) in try Kernel.File.status(of: descriptor).identity } == own
        } catch {
            throw RuntimeError("open supplied \(namespace.rawValue) namespace \(path): \(error)")
        }
        self.namespace = namespace
        descriptor = consume opened
    }

    /// Enter in user-first, mount-before-PID order; PID entry affects the next fork.
    func join() -> Errno? {
        guard !matchesCaller else { return nil }
        return descriptor.failure(in: { descriptor in
            Errno.failure { () throws(Errno) in try Kernel.Namespace.enter(descriptor, namespace) }
        })
    }

    static let joinOrder: [OCIRunPlan.Namespace] = [.user, .network, .cgroup, .ipc, .uts, .mount, .pid]
}
