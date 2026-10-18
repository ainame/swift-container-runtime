#if os(Linux)
import SystemPackage
#endif

/// A `--pidfd-socket` address, accepted as runc accepts it on Linux: a filesystem path of at most 107 bytes, which leaves
/// room for the terminating NUL in `sun_path`, or an abstract name written
/// with a leading `@` of at most 108 bytes including the `@`. Where a relative
/// path resolves is decided by the command, as in runc (see `PidfdSocket`).
/// Unlike runc, which treats an empty value as an absent option, an empty
/// value is rejected.
public struct PidfdSocketAddress: Sendable, Equatable {
    /// The size of `sun_path` on Linux.
    static let sunPathCapacity = 108

    public let path: String

    public init(_ path: String) throws {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty else { throw RuntimeError("--pidfd-socket must not be empty") }
        guard !bytes.contains(0) else { throw RuntimeError("--pidfd-socket must not contain NUL") }
        let limit = bytes[0] == UInt8(ascii: "@") ? Self.sunPathCapacity : Self.sunPathCapacity - 1
        guard bytes.count <= limit else {
            throw RuntimeError("--pidfd-socket \(path) is \(bytes.count) bytes; a Unix socket address allows \(limit)")
        }
        self.path = path
    }

    public var isAbstract: Bool { path.utf8.first == UInt8(ascii: "@") }

    /// A filesystem path that does not start with `/`.
    public var isRelative: Bool { !isAbstract && path.utf8.first != UInt8(ascii: "/") }

    /// The exact `sun_path` bytes passed to connect: a filesystem path with
    /// its terminating NUL, or an abstract name whose `@` becomes the leading
    /// NUL and which counts exactly its bytes (as in runc).
    var sunPath: [UInt8] {
        var bytes = Array(path.utf8)
        if isAbstract { bytes[0] = 0 } else { bytes.append(0) }
        return bytes
    }
}

/// The label sent with the pidfd, naming runc's init type: `standard` for a
/// container's init (`run`, `create`), `setns` for an `exec` process.
enum PidfdLabel: String {
    case standard, setns
}

#if os(Linux)
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
    let address: PidfdSocketAddress

    /// Connects to `address`. A relative path resolves against `base` when
    /// given, as runc resolves it after changing to the bundle directory
    /// (`run`, `create`, and command-form `exec`: runc `utils_linux.go`
    /// setupSpec and `exec.go` getProcess), and against the working directory
    /// otherwise (`exec --process`, which runc loads before changing
    /// directory). Absolute paths and abstract names are used as given.
    ///
    /// The process-wide working directory is never changed. A relative socket
    /// under `base` is pinned with an O_PATH handle and connected through its
    /// short `/proc/self/fd/N` name, so the 107-byte limit applies to `path`
    /// alone, as in runc, and never to `base`.
    init(connectingTo address: PidfdSocketAddress, relativeTo base: String?) throws {
        let connection: OwnedFileDescriptor
        do { connection = try Kernel.Socket.unixStream() } catch { throw RuntimeError("create --pidfd-socket connection: \(error)") }
        var target = address
        var pinned = OwnedFileDescriptor()
        if let base, address.isRelative {
            let resolved = base.hasSuffix("/") ? base + address.path : base + "/" + address.path
            do {
                pinned = try Kernel.File.openPath(resolved)
            } catch {
                throw RuntimeError("connect to --pidfd-socket \(address.path) in \(base): \(error)")
            }
            let handle = try pinned.withDescriptor { $0.rawValue }
            target = try PidfdSocketAddress("/proc/self/fd/\(handle)")
        }
        let error = connection.failure(in: { socket in
            Errno.failure { () throws(Errno) in try Kernel.Socket.connect(socket, sunPath: target.sunPath) }
        })
        try? pinned.close()
        if let error { throw RuntimeError("connect to --pidfd-socket \(address.path): \(error)") }
        self.connection = connection
        self.address = address
    }

    /// Adopts a stream that is already connected.
    init(connected connection: consuming OwnedFileDescriptor, address: PidfdSocketAddress) {
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

#endif
