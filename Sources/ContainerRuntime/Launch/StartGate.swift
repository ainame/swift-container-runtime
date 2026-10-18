#if os(Linux)
import SystemPackage

/// The start handshake between `start` and a created init.
///
/// `create` binds a SOCK_SEQPACKET listener at `start.sock` in the state
/// directory before forking, so the init inherits it. The socket file is the
/// created-to-running marker. The init has already switched to the workload
/// credentials when it serves the gate, so it cannot write to the private,
/// root-owned state directory; the marker is consumed by `start`, which runs
/// on the host with the container lock held:
///
/// 1. `start` connects and sends `request`.
/// 2. The init checks that the peer is still connected and sends an
///    `accepted` record. The marker is untouched, so a client that dies
///    before or during this step leaves the container created.
/// 3. `start` unlinks `start.sock` (the commit point) and sends `commit`.
/// 4. When the commit arrives or the connection ends, the init decides by the
///    marker's link count, read through an O_PATH handle on the socket inode
///    that it inherited: still linked, it serves the next connection
///    (created); unlinked with the commit, it calls `execve` (running);
///    unlinked without it, because the client died between steps 3 and 4,
///    it exits without executing anything (stopped).
///
/// The connection is close-on-exec: `start` sees EOF when the exec succeeded,
/// or a `LaunchRecord` failure when it did not. Unlike runc's exec FIFO (one
/// byte written before exec), this confirms the exec itself, and a start
/// client that dies before step 3 does not consume the start.
enum StartProtocol {
    static let request: [UInt8] = Array("start-v2".utf8)
    static let commit: [UInt8] = Array("commit-v2".utf8)
    /// A connected client gets this long to send its request.
    static let requestTimeout = Duration.seconds(5)
    /// Bound on each wait for the init in `start`.
    static let resultTimeout = Duration.seconds(30)
}

/// Descriptors a created init inherits for the start handshake. They are
/// close-on-exec, opened before the fork from the supervisor's mount
/// namespace, and closed explicitly before the workload executes. Neither is
/// a directory, so the init holds no handle on the host filesystem tree
/// after it has dropped privileges.
final class StartGate {
    private(set) var listener: OwnedFileDescriptor
    /// An O_PATH handle on the `start.sock` inode created by the bind, used
    /// only to read its link count.
    private(set) var marker: OwnedFileDescriptor

    init(_ container: LockedContainer) throws {
        let listener: OwnedFileDescriptor
        do { listener = try Kernel.Socket.unixSequencedPacket() } catch { throw RuntimeError.launch(.startSocket, error) }
        // sun_path is short; address the socket through the directory handle
        // so long --root paths and IDs work. The new socket file and the
        // handle on it are made under the container lock, in the private
        // directory, so both name the same inode.
        let marker: OwnedFileDescriptor
        do {
            let directory = try container.directory.descriptor.withDescriptor { $0.rawValue }
            let path = StartProtocol.sunPath("/proc/self/fd/\(directory)/\(StateFile.startSocket)")
            try listener.withDescriptor { try Kernel.Socket.bind($0, sunPath: path) }
            marker = try Kernel.File.openPath(StateFile.startSocket, in: container.directory.descriptor, noFollow: true)
        } catch {
            throw RuntimeError.launch(.startSocket, (error as? Errno) ?? .badFileDescriptor)
        }
        do {
            try listener.withDescriptor { try Kernel.Socket.listen($0, backlog: 16) }
        } catch {
            throw RuntimeError.launch(.startSocket, (error as? Errno) ?? .badFileDescriptor)
        }
        self.listener = listener
        self.marker = marker
    }

    /// Runs in the created init after the commit. Returns only on failure,
    /// or after a start that was committed but whose client then vanished.
    @unsafe
    func serve(
        file: UnsafePointer<CChar>,
        arguments: UnsafePointer<UnsafeMutablePointer<CChar>?>,
        environment: UnsafePointer<UnsafeMutablePointer<CChar>?>
    ) -> Int32 {
        while true {
            // Steps 1-2: a live client's request, acknowledged.
            let connection: OwnedFileDescriptor
            do {
                connection = try Kernel.Socket.accept(listener)
            } catch .interrupted, .connectionAbort {
                continue
            } catch {
                // Anything else ends the init at once; its exit closes the
                // queued connection, so start fails promptly. A configured
                // RLIMIT_NOFILE with no free descriptor fails create instead
                // (acceptCapacityError).
                return 125
            }
            guard receiveRequest(connection), peerIsConnected(connection) else { continue }
            guard LaunchRecord(.accepted).write(to: connection, socket: true) else { continue }

            // Step 4: wait without a deadline. Only the locked start command
            // can unlink the marker, and only before it sends the commit or
            // closes, so the link count read afterwards is final. A timeout
            // here could race with that unlink and leave a running status
            // with nothing executed.
            let committed = StartProtocol.receivePacket(connection) == StartProtocol.commit
            let status: FileStatus
            do {
                status = try marker.withDescriptor { try Kernel.File.status(of: $0) }
            } catch {
                return LaunchRecord.reportFailure(to: connection, at: .startSocket, error: (error as? Errno) ?? .badFileDescriptor, socket: true)
            }
            if status.linkCount > 0 {
                // Not consumed: still created. A commit without the unlink
                // is a protocol error reported to that client.
                if committed { _ = LaunchRecord.reportFailure(to: connection, at: .startSocket, error: .protocolError, socket: true) }
                continue
            }
            // Consumed without a commit: the start was abandoned after its
            // commit point. Exit rather than run a workload nobody started.
            guard committed else { return 125 }

            // Close every gate descriptor except the connection, whose
            // close-on-exec lifetime reports the outcome.
            try? marker.close()
            try? listener.close()
            let error = unsafe Kernel.Process.execute(file, arguments: arguments, environment: environment)
            return LaunchRecord.reportFailure(to: connection, at: .execute, error: error, socket: true)
        }
    }

    /// Checks, before the init reports readiness, that `serve` can accept a
    /// connection under the init's final RLIMIT_NOFILE. accept4 takes the
    /// lowest free descriptor below the soft limit and fails with EMFILE at
    /// once, even before a client connects, so this duplicates the listener
    /// into that same lowest free slot and closes it again. The connection
    /// later uses a real descriptor within the limit. One slot is enough: the
    /// init opens no other descriptor before serving, and serve releases each
    /// connection before its next accept. Returns nil or the error.
    func acceptCapacityError() -> Errno? {
        do {
            let duplicate = try listener.withDescriptor { try $0.duplicate() }
            try? duplicate.close()
            return nil
        } catch {
            return (error as? Errno) ?? .badFileDescriptor
        }
    }

    private func receiveRequest(_ connection: borrowing OwnedFileDescriptor) -> Bool {
        guard StartProtocol.waitReadable(connection, timeout: StartProtocol.requestTimeout) else { return false }
        return StartProtocol.receivePacket(connection) == StartProtocol.request
    }

    /// False once the client has hung up, so a start whose caller died
    /// before this point leaves the container created.
    private func peerIsConnected(_ connection: borrowing OwnedFileDescriptor) -> Bool {
        connection.poll(.peerHangup, timeout: .zero).isDisjoint(with: [.peerHangup, .hangup, .error])
    }
}

extension StartProtocol {
    /// The `sun_path` bytes of a filesystem socket path, NUL-terminated.
    fileprivate static func sunPath(_ path: String) -> [UInt8] {
        Array(path.utf8) + [0]
    }

    /// Sends one whole packet without raising SIGPIPE on a vanished peer.
    fileprivate static func sendPacket(_ owner: borrowing OwnedFileDescriptor, _ packet: [UInt8]) -> Bool {
        (try? owner.withDescriptor { descriptor in
            try packet.withUnsafeBytes { bytes in unsafe try Kernel.Socket.send(descriptor, bytes) == bytes.count }
        }) ?? false
    }

    /// Reads one packet of at most 16 bytes; nil on EOF or error.
    fileprivate static func receivePacket(_ owner: borrowing OwnedFileDescriptor) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = (try? owner.withDescriptor { descriptor in
            try buffer.withUnsafeMutableBytes { bytes in unsafe try descriptor.read(into: bytes) }
        }) ?? 0
        return count > 0 ? Array(buffer[..<count]) : nil
    }

    fileprivate static func waitReadable(_ owner: borrowing OwnedFileDescriptor, timeout: Duration) -> Bool {
        !owner.poll(.input, timeout: timeout).isEmpty
    }

    /// Asks a created init to exec its workload and waits for the outcome.
    /// The caller holds the container lock and has checked the status.
    static func start(_ container: LockedContainer) throws {
        let id = container.id.rawValue
        // Step 1: open the socket file itself without following a symlink, then
        // connect through that handle with a separate, close-on-exec connection
        // whose lifetime in the init reports the exec result.
        let socketFile: OwnedFileDescriptor
        do {
            socketFile = try Kernel.File.openPath(StateFile.startSocket, in: container.directory.descriptor, noFollow: true)
        } catch {
            throw RuntimeError("container \(id) init is not waiting for start: \(error)")
        }
        let connection: OwnedFileDescriptor
        do { connection = try Kernel.Socket.unixSequencedPacket() } catch { throw RuntimeError.launch(.startRequest, error) }
        do {
            let file = try socketFile.withDescriptor { $0.rawValue }
            try connection.withDescriptor { try Kernel.Socket.connect($0, sunPath: sunPath("/proc/self/fd/\(file)")) }
        } catch {
            throw RuntimeError("connect to container \(id) init: \(error)")
        }
        guard StartProtocol.sendPacket(connection, StartProtocol.request) else {
            throw RuntimeError("send start request to container \(id): \(Errno.current)")
        }

        // Step 2: until the acknowledgement, any failure leaves the marker and
        // therefore the created state intact.
        try waitForInit(connection, id: id, expecting: .accepted)

        // Step 3: consume the marker this command connected through, then commit.
        // A failed unlink closes the connection, which the init treats as a
        // start that never happened.
        let current = try? container.directory.descriptor.withDescriptor { directory in
            try Kernel.File.status(of: StateFile.startSocket, in: directory)
        }
        guard let current, let connectedIdentity = socketFile.identity(), connectedIdentity == current.identity else {
            throw RuntimeError("container \(id) start socket changed during start")
        }
        do {
            try container.directory.descriptor.withDescriptor { try Kernel.File.remove(StateFile.startSocket, in: $0) }
        } catch {
            throw RuntimeError.launch(.startSocket, (error as? Errno) ?? .badFileDescriptor)
        }
        guard StartProtocol.sendPacket(connection, StartProtocol.commit) else {
            throw RuntimeError("container \(id) init vanished before the start commit: \(Errno.current)")
        }

        // Step 4: EOF means execve closed the connection.
        try waitForInit(connection, id: id, expecting: nil)
    }

    /// Waits a bounded time for the init's next record: `expected`, or EOF when
    /// `expected` is nil. A failure record becomes its launch error.
    private static func waitForInit(_ connection: borrowing OwnedFileDescriptor, id: String, expecting expected: LaunchRecord.Kind?) throws {
        guard StartProtocol.waitReadable(connection, timeout: StartProtocol.resultTimeout) else {
            throw RuntimeError("container \(id) init did not answer the start request within 30 seconds")
        }
        switch LaunchRecord.read(from: connection) {
        case let .record(record):
            let kind = LaunchRecord.Kind(rawValue: record.kind)
            if kind == .failure {
                throw RuntimeError.launch(LaunchStage(rawValue: record.stage) ?? .startRequest, record.error)
            }
            guard let expected, kind == expected else { throw RuntimeError.launch(.startRequest, .protocolError) }
        case .end:
            guard expected == nil else {
                throw RuntimeError("container \(id) init closed the start connection without starting")
            }
        case let .failed(error):
            throw RuntimeError.launch(.startRequest, error)
        }
    }
}
#endif
