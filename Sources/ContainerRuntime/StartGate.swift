#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import LinuxAPI
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
    static let requestTimeoutMilliseconds: Int32 = 5_000
    /// Bound on each wait for the init in `start`.
    static let resultTimeoutMilliseconds: Int32 = 30_000
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
        let socketRaw = linux_unix_seqpacket_socket()
        guard socketRaw >= 0 else { throw RuntimeError.launch(.startSocket) }
        let listener = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: socketRaw))
        // sun_path is short; address the socket through the directory handle
        // so long --root paths and IDs work. The new socket file and the
        // handle on it are made under the container lock, in the private
        // directory, so both name the same inode.
        let bound = try container.directory.descriptor.withDescriptor { directoryDescriptor in
            try listener.withDescriptor { socket in
                StartProtocol.addressCall(socket, path: "/proc/self/fd/\(directoryDescriptor.rawValue)/\(StateFile.startSocket)", connecting: false)
            }
        }
        guard bound == 0 else { throw RuntimeError.launch(.startSocket) }
        let markerRaw = try container.directory.descriptor.withDescriptor {
            unsafe linux_open_path($0.rawValue, StateFile.startSocket, O_NOFOLLOW)
        }
        guard markerRaw >= 0 else { throw RuntimeError.launch(.startSocket) }
        let marker = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: markerRaw))
        guard try listener.withDescriptor({ listen($0.rawValue, 16) }) == 0 else { throw RuntimeError.launch(.startSocket) }
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
            let raw = (try? listener.withDescriptor { linux_accept_cloexec($0.rawValue) }) ?? -1
            guard raw >= 0 else {
                // Anything else ends the init at once; its exit closes the
                // queued connection, so start fails promptly. A configured
                // RLIMIT_NOFILE with no free descriptor fails create instead
                // (acceptCapacityError).
                if errno == EINTR || errno == ECONNABORTED { continue }
                return 125
            }
            let connection = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
            guard receiveRequest(connection), peerIsConnected(connection) else { continue }
            guard LaunchRecord(.accepted).write(to: connection, socket: true) else { continue }

            // Step 4: wait without a deadline. Only the locked start command
            // can unlink the marker, and only before it sends the commit or
            // closes, so the link count read afterwards is final. A timeout
            // here could race with that unlink and leave a running status
            // with nothing executed.
            let committed = StartProtocol.receivePacket(connection) == StartProtocol.commit
            var status = stat()
            let inspected = (try? marker.withDescriptor { unsafe fstat($0.rawValue, &status) }) ?? -1
            guard inspected == 0 else { return LaunchRecord.reportFailure(to: connection, at: .startSocket, socket: true) }
            if status.st_nlink > 0 {
                // Not consumed: still created. A commit without the unlink
                // is a protocol error reported to that client.
                if committed { _ = LaunchRecord.reportFailure(to: connection, at: .startSocket, code: EPROTO, socket: true) }
                continue
            }
            // Consumed without a commit: the start was abandoned after its
            // commit point. Exit rather than run a workload nobody started.
            guard committed else { return 125 }

            // Close every gate descriptor except the connection, whose
            // close-on-exec lifetime reports the outcome.
            try? marker.close()
            try? listener.close()
            _ = unsafe execve(file, arguments, environment)
            return LaunchRecord.reportFailure(to: connection, at: .execute, socket: true)
        }
    }

    /// Checks, before the init reports readiness, that `serve` can accept a
    /// connection under the init's final RLIMIT_NOFILE. accept4 takes the
    /// lowest free descriptor below the soft limit and fails with EMFILE at
    /// once, even before a client connects, so this duplicates the listener
    /// into that same lowest free slot and closes it again. The connection
    /// later uses a real descriptor within the limit. One slot is enough: the
    /// init opens no other descriptor before serving, and serve releases each
    /// connection before its next accept. Returns 0 or errno.
    func acceptCapacityError() -> Int32 {
        guard let raw = try? listener.withDescriptor({ dup($0.rawValue) }) else { return EBADF }
        guard raw >= 0 else { return errno }
        _ = close(raw)
        return 0
    }

    private func receiveRequest(_ connection: borrowing OwnedFileDescriptor) -> Bool {
        guard StartProtocol.waitReadable(connection, milliseconds: StartProtocol.requestTimeoutMilliseconds) else { return false }
        return StartProtocol.receivePacket(connection) == StartProtocol.request
    }

    /// False once the client has hung up, so a start whose caller died
    /// before this point leaves the container created.
    private func peerIsConnected(_ connection: borrowing OwnedFileDescriptor) -> Bool {
        let revents = (try? connection.withDescriptor { descriptor -> Int16 in
            var peer = pollfd(fd: descriptor.rawValue, events: Int16(POLLRDHUP), revents: 0)
            var result: Int32
            repeat { result = unsafe poll(&peer, 1, 0) } while result < 0 && errno == EINTR
            return result < 0 ? Int16(POLLERR) : peer.revents
        }) ?? Int16(POLLERR)
        return revents & Int16(POLLRDHUP | POLLHUP | POLLERR) == 0
    }
}

extension StartProtocol {
    /// Binds or connects `socket` to a filesystem path shorter than `sun_path`.
    static func addressCall(_ socket: FileDescriptor, path: String, connecting: Bool) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            errno = ENAMETOOLONG
            return -1
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { unsafe buffer[index] = byte }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                unsafe connecting ? connect(socket.rawValue, generic, length) : bind(socket.rawValue, generic, length)
            }
        }
    }

    /// Sends one whole packet without raising SIGPIPE on a vanished peer.
    static func sendPacket(_ owner: borrowing OwnedFileDescriptor, _ packet: [UInt8]) -> Bool {
        (try? owner.withDescriptor { descriptor in
            packet.withUnsafeBytes { bytes in
                var result: Int
                repeat { result = unsafe send(descriptor.rawValue, bytes.baseAddress!, bytes.count, Int32(MSG_NOSIGNAL)) }
                while result < 0 && errno == EINTR
                return result == bytes.count
            }
        }) ?? false
    }

    /// Reads one packet of at most 16 bytes; nil on EOF or error.
    static func receivePacket(_ owner: borrowing OwnedFileDescriptor) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = (try? owner.withDescriptor { descriptor in
            try buffer.withUnsafeMutableBytes { bytes in unsafe try descriptor.read(into: bytes) }
        }) ?? 0
        return count > 0 ? Array(buffer[..<count]) : nil
    }

    static func waitReadable(_ owner: borrowing OwnedFileDescriptor, milliseconds: Int32) -> Bool {
        owner.poll(events: Int16(POLLIN), milliseconds: milliseconds) != 0
    }

    /// Asks a created init to exec its workload and waits for the outcome.
    /// The caller holds the container lock and has checked the status.
    static func start(_ container: LockedContainer) throws {
        let id = container.id.rawValue
        // Step 1: open the socket file itself without following a symlink, then
        // connect through that handle with a separate, close-on-exec connection
        // whose lifetime in the init reports the exec result.
        let socketFileRaw = try container.directory.descriptor.withDescriptor {
            unsafe linux_open_path($0.rawValue, StateFile.startSocket, O_NOFOLLOW)
        }
        guard socketFileRaw >= 0 else {
            throw RuntimeError("container \(id) init is not waiting for start: \(Errno(rawValue: errno))")
        }
        let socketFile = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: socketFileRaw))
        let connectionRaw = linux_unix_seqpacket_socket()
        guard connectionRaw >= 0 else { throw RuntimeError.launch(.startRequest) }
        let connection = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: connectionRaw))
        let connected = try socketFile.withDescriptor { file in
            try connection.withDescriptor { socket in
                StartProtocol.addressCall(socket, path: "/proc/self/fd/\(file.rawValue)", connecting: true)
            }
        }
        guard connected == 0 else {
            throw RuntimeError("connect to container \(id) init: \(Errno(rawValue: errno))")
        }
        guard StartProtocol.sendPacket(connection, StartProtocol.request) else {
            throw RuntimeError("send start request to container \(id): \(Errno(rawValue: errno))")
        }

        // Step 2: until the acknowledgement, any failure leaves the marker and
        // therefore the created state intact.
        try awaitInit(connection, id: id, expecting: .accepted)

        // Step 3: consume the marker this command connected through, then commit.
        // A failed unlink closes the connection, which the init treats as a
        // start that never happened.
        var current = stat()
        let inspected = try container.directory.descriptor.withDescriptor {
            unsafe fstatat($0.rawValue, StateFile.startSocket, &current, AT_SYMLINK_NOFOLLOW)
        }
        guard inspected == 0, let connectedIdentity = socketFile.identity(),
              connectedIdentity.device == current.st_dev, connectedIdentity.inode == current.st_ino else {
            throw RuntimeError("container \(id) start socket changed during start")
        }
        let unlinked = try container.directory.descriptor.withDescriptor { unsafe unlinkat($0.rawValue, StateFile.startSocket, 0) }
        guard unlinked == 0 else { throw RuntimeError.launch(.startSocket) }
        guard StartProtocol.sendPacket(connection, StartProtocol.commit) else {
            throw RuntimeError("container \(id) init vanished before the start commit: \(Errno(rawValue: errno))")
        }

        // Step 4: EOF means execve closed the connection.
        try awaitInit(connection, id: id, expecting: nil)
    }

    /// Waits a bounded time for the init's next record: `expected`, or EOF when
    /// `expected` is nil. A failure record becomes its launch error.
    static func awaitInit(_ connection: borrowing OwnedFileDescriptor, id: String, expecting expected: LaunchRecord.Kind?) throws {
        guard StartProtocol.waitReadable(connection, milliseconds: StartProtocol.resultTimeoutMilliseconds) else {
            throw RuntimeError("container \(id) init did not answer the start request within 30 seconds")
        }
        switch LaunchRecord.read(from: connection) {
        case let .record(record):
            let kind = LaunchRecord.Kind(rawValue: record.kind)
            if kind == .failure {
                throw RuntimeError.launch(LaunchStage(rawValue: record.stage) ?? .startRequest, record.code)
            }
            guard let expected, kind == expected else { throw RuntimeError.launch(.startRequest, EPROTO) }
        case .end:
            guard expected == nil else {
                throw RuntimeError("container \(id) init closed the start connection without starting")
            }
        case let .failed(code):
            throw RuntimeError.launch(.startRequest, code)
        }
    }
}
#endif
