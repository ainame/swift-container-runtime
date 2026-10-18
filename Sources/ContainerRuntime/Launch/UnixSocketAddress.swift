import SystemPackage

/// A `--pidfd-socket` or `--console-socket` address, accepted as runc accepts
/// it on Linux: a filesystem path of at most 107 bytes, which leaves room for
/// the terminating NUL in `sun_path`, or an abstract name written with a
/// leading `@` of at most 108 bytes including the `@`. Where a relative path
/// resolves is decided by the command, as in runc (see `connect(relativeTo:)`).
/// Unlike runc, which treats an empty value as an absent option, an empty
/// value is rejected.
public struct UnixSocketAddress: Sendable, Equatable {
    /// The size of `sun_path` on Linux.
    static let sunPathCapacity = 108

    /// The address as given: a path, or `@` and an abstract name.
    public let path: String
    /// The option that supplied it, which errors name.
    public let option: String

    /// - Throws: `RuntimeError` for an empty address, NUL, or one too long
    ///   for `sun_path`.
    public init(_ path: String, option: String = "--pidfd-socket") throws {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty else { throw RuntimeError("\(option) must not be empty") }
        guard !bytes.contains(0) else { throw RuntimeError("\(option) must not contain NUL") }
        let limit = bytes[0] == UInt8(ascii: "@") ? Self.sunPathCapacity : Self.sunPathCapacity - 1
        guard bytes.count <= limit else {
            throw RuntimeError("\(option) \(path) is \(bytes.count) bytes; a Unix socket address allows \(limit)")
        }
        self.path = path
        self.option = option
    }

    /// An abstract-namespace name (written with a leading `@`), not a path.
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

    /// A close-on-exec stream connection to this address, dialed by the
    /// supervisor just before the launch forks. A relative path resolves
    /// against `base` when given, as runc resolves it after changing to the
    /// bundle directory (`run`, `create`, and command-form `exec`: runc
    /// `utils_linux.go` setupSpec and `exec.go` getProcess), and against the
    /// working directory otherwise (`exec --process`, which runc loads before
    /// changing directory). Absolute paths and abstract names are used as given.
    ///
    /// The process-wide working directory is never changed. A relative socket
    /// under `base` is pinned with an O_PATH handle and connected through its
    /// short `/proc/self/fd/N` name, so the 107-byte limit applies to `path`
    /// alone, as in runc, and never to `base`.
    func connect(relativeTo base: String?) throws -> OwnedFileDescriptor {
        let connection: OwnedFileDescriptor
        do { connection = try Kernel.Socket.unixStream() } catch { throw RuntimeError("create \(option) connection: \(error)") }
        var target = self
        var pinned = OwnedFileDescriptor()
        if let base, isRelative {
            let resolved = base.hasSuffix("/") ? base + path : base + "/" + path
            do {
                pinned = try Kernel.File.openPath(resolved)
            } catch {
                throw RuntimeError("connect to \(option) \(path) in \(base): \(error)")
            }
            let handle = try pinned.withDescriptor { $0.rawValue }
            target = try UnixSocketAddress("/proc/self/fd/\(handle)", option: option)
        }
        let error = connection.failure(in: { socket in
            Errno.failure { () throws(Errno) in try Kernel.Socket.connect(socket, sunPath: target.sunPath) }
        })
        try? pinned.close()
        if let error { throw RuntimeError("connect to \(option) \(path): \(error)") }
        return connection
    }
}
