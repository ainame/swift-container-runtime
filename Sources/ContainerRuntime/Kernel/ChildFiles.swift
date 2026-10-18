#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
#if os(Linux)
import LinuxAPI
#endif
import SystemPackage

/// File operations on C strings, for code between fork and exec that holds
/// prepared buffers. The `String` forms elsewhere in Kernel suit the rest.
extension Kernel.File {
    /// mkdirat(2) of a C string.
    static func makeDirectory(_ path: UnsafePointer<CChar>, in directory: FileDescriptor? = nil, permissions: FilePermissions) throws(Errno) {
        guard unsafe mkdirat(directory?.rawValue ?? AT_FDCWD, path, mode_t(permissions.rawValue)) == 0 else { throw .current }
    }

    /// An empty regular file `name` in `directory`, as openat(2) with
    /// O_CREAT|O_EXCL|O_NOFOLLOW, closed again at once. Any existing entry,
    /// including a dangling symbolic link, fails with EEXIST.
    static func makeEmptyFile(_ name: UnsafePointer<CChar>, in directory: FileDescriptor, permissions: FilePermissions) throws(Errno) {
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let raw = unsafe openat(directory.rawValue, name, flags, mode_t(permissions.rawValue))
        guard raw >= 0 else { throw .current }
        _ = close(raw)
    }

    /// Writes `value` (NUL-terminated, without the NUL) to the procfs file
    /// at `path` in one write(2). The file must be on procfs, so an image's
    /// ordinary file at that path is never written instead.
    static func writeProcFile(_ path: UnsafePointer<CChar>, _ value: UnsafePointer<CChar>) throws(Errno) {
        #if os(Linux)
        let raw = unsafe openat(AT_FDCWD, path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard raw >= 0 else { throw .current }
        defer { _ = close(raw) }
        var filesystem = statfs()
        guard unsafe fstatfs(raw, &filesystem) == 0 else { throw .current }
        // PROC_SUPER_MAGIC from <linux/magic.h>.
        guard UInt64(truncatingIfNeeded: filesystem.f_type) == 0x9fa0 else { throw .notSupported }
        let bytes = unsafe UnsafeRawBufferPointer(start: value, count: strlen(value))
        let written: Int
        do { written = try unsafe FileDescriptor(rawValue: raw).write(bytes) } catch { throw (error as? Errno) ?? .ioError }
        guard written == bytes.count else { throw .ioError }
        #else
        throw .noFunction
        #endif
    }

    /// mknodat(2) of a character device.
    static func makeCharacterDevice(_ name: UnsafePointer<CChar>, in directory: FileDescriptor, permissions: FilePermissions, device: UInt64) throws(Errno) {
        let mode = mode_t(fileTypeCharacterDevice) | mode_t(permissions.rawValue)
        guard unsafe mknodat(directory.rawValue, name, mode, dev_t(truncatingIfNeeded: device)) == 0 else { throw .current }
    }

    /// symlinkat(2): `name` in `directory` pointing at `target`.
    static func makeSymbolicLink(_ name: UnsafePointer<CChar>, to target: UnsafePointer<CChar>, in directory: FileDescriptor) throws(Errno) {
        guard unsafe symlinkat(target, directory.rawValue, name) == 0 else { throw .current }
    }

    /// stat(2) of a C string path, following symbolic links.
    static func status(atPath path: UnsafePointer<CChar>) throws(Errno) -> FileStatus {
        var status = stat()
        guard unsafe stat(path, &status) == 0 else { throw .current }
        return FileStatus(status)
    }

    /// access(X_OK) with the current credentials.
    static func checkExecutable(_ path: UnsafePointer<CChar>) throws(Errno) {
        guard unsafe access(path, X_OK) == 0 else { throw .current }
    }

    /// fchown(2) to `user`, keeping the group.
    static func changeOwner(_ descriptor: FileDescriptor, to user: uid_t) throws(Errno) {
        guard fchown(descriptor.rawValue, user, gid_t.max) == 0 else { throw .current }
    }

    /// A close-on-exec O_PATH handle (Linux) relative to `directory` (or the
    /// current directory), with `.directory` and `.noFollow` as options.
    static func openPath(
        _ path: UnsafePointer<CChar>, in directory: FileDescriptor? = nil, options: FileDescriptor.OpenOptions = []
    ) throws(Errno) -> OwnedFileDescriptor {
        #if os(Linux)
        let raw = unsafe linux_open_path(directory?.rawValue ?? AT_FDCWD, path, options.rawValue)
        guard raw >= 0 else { throw .current }
        return OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
        #else
        throw .noFunction
        #endif
    }

    /// openat2(RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS) O_PATH handle (Linux
    /// 5.6+): absolute links and `..` stay below `root`, magic links fail
    /// with ELOOP, and `.noFollow` keeps a final symbolic link itself.
    static func openPath(
        _ path: UnsafePointer<CChar>, beneath root: FileDescriptor, options: FileDescriptor.OpenOptions = []
    ) throws(Errno) -> OwnedFileDescriptor {
        #if os(Linux)
        let raw = unsafe linux_open_path_in_root(root.rawValue, path, options.rawValue)
        guard raw >= 0 else { throw .current }
        return OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
        #else
        throw .noFunction
        #endif
    }
}

extension Kernel.File {
    /// `openPath(_:beneath:options:)`, or nil when the path does not exist.
    static func openPathIfPresent(
        _ path: UnsafePointer<CChar>, beneath root: FileDescriptor, options: FileDescriptor.OpenOptions = []
    ) throws(Errno) -> OwnedFileDescriptor? {
        do {
            return try unsafe openPath(path, beneath: root, options: options)
        } catch .noSuchFileOrDirectory {
            return nil
        }
    }
}

extension FileStatus {
    var isDirectory: Bool { mode & fileTypeMask == fileTypeDirectory }
    var isCharacterDevice: Bool { mode & fileTypeMask == fileTypeCharacterDevice }
}

// <sys/stat.h> file type bits, identical on Linux and Darwin. LinuxAPI also
// declares S_IF* on Linux, which makes the libc names ambiguous here.
private let fileTypeMask: UInt32 = 0o170000
private let fileTypeDirectory: UInt32 = 0o040000
private let fileTypeCharacterDevice: UInt32 = 0o020000
