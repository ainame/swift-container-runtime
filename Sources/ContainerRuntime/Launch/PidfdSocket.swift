import SystemPackage

/// The label sent with the pidfd, naming runc's init type: `standard` for a
/// container's init (`run`, `create`), `setns` for an `exec` process.
enum PidfdLabel: String {
    case standard, setns
}

/// A stream connection to the `--pidfd-socket` listener. The runtime dials it
/// on the host in the locked launch scope, after the container ID, state, and
/// plan are accepted and immediately before the launch forks, as runc dials
/// it after loading the container and its spec. The address is resolved in
/// the caller's mount and network namespaces, and the listener's peer
/// credentials name this runtime process, as with runc. The connection is
/// close-on-exec, so no workload inherits it.
///
/// The forked process that becomes the init or exec process inherits it and,
/// once in the container's namespaces and root but before no_new_privs,
/// credentials, capabilities, or readiness, sends a pidfd for itself
/// (`handOff`). It then closes both, so a waiting created init holds neither.
/// The runtime's own copy closes when the launch returns; in the foreground,
/// the launcher's copy lives until the workload exits, as runc keeps its
/// connection until it exits.
final class PidfdSocket {
    private(set) var connection: OwnedFileDescriptor
    let address: UnixSocketAddress

    /// Connects to `address`; see ``UnixSocketAddress/connect(relativeTo:)``
    /// for where a relative path resolves.
    init(connectingTo address: UnixSocketAddress, relativeTo base: String?) throws {
        connection = try address.connect(relativeTo: base)
        self.address = address
    }

    /// Adopts a stream that is already connected.
    init(connected connection: consuming OwnedFileDescriptor, address: UnixSocketAddress) {
        self.connection = connection
        self.address = address
    }

    /// Runs in the forked init or exec process, in its final PID namespace,
    /// so `pidfd_open(getpid())` names this process and never a PID read
    /// elsewhere. Sends the pidfd with `label` as runc's `setupPidfd`, then
    /// closes the pidfd and the connection on every path. Returns nil or the failure.
    func handOff(label: PidfdLabel) -> LaunchFailure? {
        defer { try? connection.close() }
        let sendError: Errno?
        do {
            // Initialized in place: a deferred initialization of this owner
            // trips a Swift 6.4.1 noncopyable-copy diagnostic.
            let pidfd = try Kernel.Pidfd.open(Kernel.Process.id)
            sendError = connection.failure(in: { socket in
                pidfd.failure(in: { descriptor in
                    Errno.failure { () throws(Errno) in
                        try Kernel.Socket.sendDescriptor(descriptor, over: socket, payload: Array(label.rawValue.utf8))
                    }
                })
            })
        } catch {
            return LaunchFailure(stage: .pidfdOpen, error: error)
        }
        return sendError.map { LaunchFailure(stage: .pidfdSend, error: $0) }
    }

    var isClosed: Bool { (try? connection.withDescriptor { _ in }) == nil }

    func close() {
        try? connection.close()
    }
}

