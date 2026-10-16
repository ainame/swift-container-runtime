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
/// directory before forking, so the init inherits it. After setup the init
/// accepts connections. For a valid request from a peer that is still
/// connected, it unlinks `start.sock` (the created-to-running marker) and
/// calls `execve`. The connection is close-on-exec: the client sees EOF when
/// the exec succeeded, or a `LaunchRecord` failure when it did not. A client
/// that disconnects before the init checks it never starts the workload; one
/// that dies after that check cannot stop the exec that is already underway.
///
/// Unlike runc's exec FIFO (one byte written before exec), this confirms the
/// exec itself, and a start client that dies before sending its request does
/// not consume the start.
enum StartProtocol {
    static let request: [UInt8] = Array("start-v1".utf8)
    /// A connected client gets this long to send its request.
    static let requestTimeoutMilliseconds: Int32 = 5_000
    /// Bound on the exec result wait in `start`.
    static let resultTimeoutMilliseconds: Int32 = 30_000
}

/// Binds or connects `socket` to a filesystem path shorter than `sun_path`.
private func unixAddressCall(_ socket: FileDescriptor, path: String, connecting: Bool) -> Int32 {
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

/// Descriptors a created init inherits for the start handshake. They are
/// close-on-exec and opened before the fork, from the supervisor's mount
/// namespace.
final class StartGate {
    let listener: OwnedFileDescriptor
    /// An O_PATH handle on the state directory. It is a separate open file
    /// description, so it never carries the container lock.
    let directory: OwnedFileDescriptor

    init(_ container: LockedContainer) throws {
        let directoryRaw = try container.directory.withDescriptor { unsafe linux_open_path($0.rawValue, ".", O_DIRECTORY) }
        guard directoryRaw >= 0 else { throw launchError(.startSocket) }
        let directory = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: directoryRaw))
        let socketRaw = linux_unix_seqpacket_socket()
        guard socketRaw >= 0 else { throw launchError(.startSocket) }
        let listener = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: socketRaw))
        // sun_path is short; address the socket through the directory handle
        // so long --root paths and IDs work.
        let bound = try directory.withDescriptor { directoryDescriptor in
            try listener.withDescriptor { socket in
                unixAddressCall(socket, path: "/proc/self/fd/\(directoryDescriptor.rawValue)/\(StateFile.startSocket)", connecting: false)
            }
        }
        guard bound == 0 else { throw launchError(.startSocket) }
        guard try listener.withDescriptor({ listen($0.rawValue, 16) }) == 0 else { throw launchError(.startSocket) }
        self.listener = listener
        self.directory = directory
    }

    /// Runs in the created init after the commit. Returns only on failure.
    @unsafe
    func serve(
        arguments: UnsafePointer<UnsafeMutablePointer<CChar>?>,
        environment: UnsafePointer<UnsafeMutablePointer<CChar>?>
    ) -> Int32 {
        while true {
            let raw = (try? listener.withDescriptor { linux_accept_cloexec($0.rawValue) }) ?? -1
            guard raw >= 0 else {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return 125
            }
            let connection = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
            guard receiveRequest(connection), peerIsConnected(connection) else { continue }
            // This gate currently runs as root. Future credential/capability
            // setup must preserve the ability to unlink this root-owned socket
            // or move marker consumption to the host-side control protocol.
            let unlinked = (try? directory.withDescriptor { unsafe unlinkat($0.rawValue, StateFile.startSocket, 0) }) ?? -1
            guard unlinked == 0 else { return failureStatus(connection, .startSocket, socket: true) }
            _ = unsafe execve(arguments[0]!, arguments, environment)
            return failureStatus(connection, .execute, socket: true)
        }
    }

    private func receiveRequest(_ connection: borrowing OwnedFileDescriptor) -> Bool {
        guard waitReadable(connection, milliseconds: StartProtocol.requestTimeoutMilliseconds) else { return false }
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = (try? connection.withDescriptor { descriptor in
            try buffer.withUnsafeMutableBytes { bytes in unsafe try descriptor.read(into: bytes) }
        }) ?? -1
        return count == StartProtocol.request.count && Array(buffer[..<count]) == StartProtocol.request
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

private func waitReadable(_ owner: borrowing OwnedFileDescriptor, milliseconds: Int32) -> Bool {
    pollEvents(owner, events: Int16(POLLIN), milliseconds: milliseconds) != 0
}

/// Asks a created init to exec its workload and waits for the outcome.
/// The caller holds the container lock and has checked the status.
func requestStart(_ container: LockedContainer) throws {
    let id = container.id.rawValue
    // Open the socket file itself without following a symlink, then
    // connect through that handle.
    let socketFileRaw = try container.directory.withDescriptor {
        unsafe linux_open_path($0.rawValue, StateFile.startSocket, O_NOFOLLOW)
    }
    guard socketFileRaw >= 0 else {
        throw RuntimeError("container \(id) init is not waiting for start: \(Errno(rawValue: errno))")
    }
    let socketFile = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: socketFileRaw))
    // Use a separate connection whose close-on-exec lifetime reports the exec result.
    let connectionRaw = linux_unix_seqpacket_socket()
    guard connectionRaw >= 0 else { throw launchError(.startRequest) }
    let connection = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: connectionRaw))
    let connected = try socketFile.withDescriptor { file in
        try connection.withDescriptor { socket in
            unixAddressCall(socket, path: "/proc/self/fd/\(file.rawValue)", connecting: true)
        }
    }
    guard connected == 0 else {
        throw RuntimeError("connect to container \(id) init: \(Errno(rawValue: errno))")
    }
    // Send one complete packet; a lost peer must not raise SIGPIPE in the CLI.
    let sent = try connection.withDescriptor { descriptor in
        StartProtocol.request.withUnsafeBytes { bytes in
            var result: Int
            repeat { result = unsafe send(descriptor.rawValue, bytes.baseAddress!, bytes.count, Int32(MSG_NOSIGNAL)) }
            while result < 0 && errno == EINTR
            return result
        }
    }
    guard sent == StartProtocol.request.count else {
        throw RuntimeError("send start request to container \(id): \(Errno(rawValue: errno))")
    }
    // Bound the acknowledgement wait, then distinguish an exec error from normal EOF.
    guard waitReadable(connection, milliseconds: StartProtocol.resultTimeoutMilliseconds) else {
        throw RuntimeError("container \(id) init did not report its exec result within 30 seconds")
    }
    switch readRecord(connection) {
    case let .record(record):
        guard LaunchRecord.Kind(rawValue: record.kind) == .failure else { throw launchError(.startRequest, EPROTO) }
        let stage = LaunchStage(rawValue: record.stage) ?? .startRequest
        throw launchError(stage, record.code)
    case .end:
        // EOF: execve closed the connection, unless the init gave up
        // without consuming the start socket.
        guard try !entryExists(container.directory, StateFile.startSocket) else {
            throw RuntimeError("container \(id) init closed the start connection without starting")
        }
    case let .failed(code):
        throw launchError(.startRequest, code)
    }
}
#endif
