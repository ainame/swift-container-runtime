#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import LinuxAPI
import SystemPackage
#endif

/// A `--pidfd-socket` address, accepted as runc's Go `net.DialUnix("unix")`
/// accepts it on Linux: a filesystem path of at most 107 bytes, which leaves
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

    /// The `sun_path` bytes: an abstract name's `@` becomes its leading NUL.
    var sunPath: [UInt8] {
        var bytes = Array(path.utf8)
        if isAbstract { bytes[0] = 0 }
        return bytes
    }

    /// The `sun_path` length passed to connect: a filesystem path counts its
    /// terminating NUL, an abstract name counts exactly its bytes (as Go).
    var sunPathLength: Int { path.utf8.count + (isAbstract ? 0 : 1) }
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
        let raw = linux_unix_stream_socket()
        guard raw >= 0 else { throw RuntimeError("create --pidfd-socket connection: \(Errno(rawValue: errno))") }
        let connection = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
        var target = address
        var pinned = OwnedFileDescriptor()
        if let base, address.isRelative {
            let resolved = base.hasSuffix("/") ? base + address.path : base + "/" + address.path
            let handle = resolved.withCString { unsafe linux_open_path(AT_FDCWD, $0, 0) }
            guard handle >= 0 else {
                throw RuntimeError("connect to --pidfd-socket \(address.path) in \(base): \(Errno(rawValue: errno))")
            }
            pinned = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: handle))
            target = try PidfdSocketAddress("/proc/self/fd/\(handle)")
        }
        let code = try connection.withDescriptor { Self.connect($0, to: target) }
        try? pinned.close()
        guard code == 0 else {
            throw RuntimeError("connect to --pidfd-socket \(address.path): \(Errno(rawValue: code))")
        }
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
    /// closes the pidfd and the connection on every path. Returns the failing
    /// stage and errno, or nil.
    func handOff(label: PidfdLabel) -> (stage: LaunchStage, code: Int32)? {
        defer { try? connection.close() }
        let raw = linux_pidfd_open(getpid())
        guard raw >= 0 else { return (.pidfdOpen, errno) }
        let pidfd = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
        let code = (try? connection.withDescriptor { socket in
            try pidfd.withDescriptor { Self.send($0, over: socket, label: Array(label.rawValue.utf8)) }
        }) ?? EBADF
        return code == 0 ? nil : (.pidfdSend, code)
    }

    var isClosed: Bool { (try? connection.withDescriptor { _ in }) == nil }

    func close() {
        try? connection.close()
    }
}

private extension PidfdSocket {
    /// Connects a blocking stream socket to `address`. Returns 0 or errno.
    static func connect(_ socket: FileDescriptor, to address: PidfdSocketAddress) -> Int32 {
        var storage = sockaddr_un()
        storage.sun_family = sa_family_t(AF_UNIX)
        let path = address.sunPath
        withUnsafeMutableBytes(of: &storage.sun_path) { buffer in
            for (index, byte) in path.enumerated() { unsafe buffer[index] = byte }
        }
        // sun_path directly follows the two-byte sun_family.
        let length = socklen_t(MemoryLayout<sa_family_t>.size + address.sunPathLength)
        let result = withUnsafePointer(to: &storage) { pointer in
            unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                unsafe LinuxAPI.connect(socket.rawValue, generic, length)
            }
        }
        return result == 0 ? 0 : errno
    }

    /// Sends `label` and one SCM_RIGHTS descriptor in a single message, as runc's
    /// `cmsg.SendRawFd`: no length prefix or encoding, the label bytes are the
    /// whole payload. MSG_NOSIGNAL turns a vanished listener into EPIPE instead
    /// of SIGPIPE, and EINTR retries. A short send (not expected for a few bytes
    /// on a stream) is EIO. Returns 0 or errno.
    static func send(_ descriptor: FileDescriptor, over socket: FileDescriptor, label: [UInt8]) -> Int32 {
        let payloadSize = MemoryLayout<Int32>.size
        let space = linux_cmsg_space(payloadSize)
        // CMSG_LEN(0) is the aligned header size, where CMSG_DATA begins.
        let dataOffset = linux_cmsg_len(0)
        guard dataOffset + payloadSize <= space else { return EINVAL }
        var header = cmsghdr()
        header.cmsg_len = numericCast(linux_cmsg_len(payloadSize))
        header.cmsg_level = Int32(SOL_SOCKET)
        header.cmsg_type = Int32(SCM_RIGHTS)
        var payload = label
        return payload.withUnsafeMutableBytes { bytes in
            // Raw control bytes with cmsghdr's alignment, zeroed so padding is
            // defined. The header value and the descriptor are copied in as plain
            // bytes at disjoint offsets; the memory is never bound to cmsghdr.
            withUnsafeTemporaryAllocation(byteCount: space, alignment: MemoryLayout<cmsghdr>.alignment) { control in
                unsafe control.initializeMemory(as: UInt8.self, repeating: 0)
                unsafe control.storeBytes(of: header, toByteOffset: 0, as: cmsghdr.self)
                unsafe control.storeBytes(of: descriptor.rawValue, toByteOffset: dataOffset, as: Int32.self)
                var vector = unsafe iovec(iov_base: bytes.baseAddress, iov_len: bytes.count)
                return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                    var message = unsafe msghdr()
                    unsafe message.msg_iov = vectorPointer
                    unsafe message.msg_iovlen = 1
                    unsafe message.msg_control = control.baseAddress
                    unsafe message.msg_controllen = numericCast(space)
                    var sent: Int
                    repeat { sent = unsafe sendmsg(socket.rawValue, &message, Int32(MSG_NOSIGNAL)) }
                    while sent < 0 && errno == EINTR
                    guard sent >= 0 else { return errno }
                    return sent == bytes.count ? 0 : EIO
                }
            }
        }
    }
}
#endif
