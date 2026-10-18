#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
#if os(Linux)
// statfs and fstatfs are declared through LinuxAPI's <sys/statfs.h>.
import LinuxAPI
#endif
import SystemPackage

/// The `*at` file operations swift-system does not offer. A nil `directory`
/// means the current directory; descriptors are always close-on-exec.
extension Kernel.File {
    /// openat(2).
    static func open(
        _ path: String, in directory: FileDescriptor? = nil, _ access: FileDescriptor.AccessMode,
        options: FileDescriptor.OpenOptions = [], permissions: FilePermissions = []
    ) throws(Errno) -> OwnedFileDescriptor {
        OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: try openRaw(
            path, in: directory?.rawValue ?? AT_FDCWD, access, options, permissions)))
    }

    /// openat2 RESOLVE_IN_ROOT|RESOLVE_NO_MAGICLINKS for setup paths built
    /// in Swift. All absolute links are interpreted from the pinned root.
    static func openPathInRoot(_ path: String, beneath root: FileDescriptor, options: FileDescriptor.OpenOptions = []) throws(Errno) -> OwnedFileDescriptor {
        #if os(Linux)
        let raw = unsafe linux_open_path_in_root(root.rawValue, path, options.rawValue)
        guard raw >= 0 else { throw .current }
        return OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
        #else
        throw .noFunction
        #endif
    }

    /// openat(2) relative to an owned directory, kept open throughout.
    static func open(
        _ path: String, in directory: borrowing OwnedFileDescriptor, _ access: FileDescriptor.AccessMode,
        options: FileDescriptor.OpenOptions = [], permissions: FilePermissions = []
    ) throws(Errno) -> OwnedFileDescriptor {
        let raw: Int32
        do {
            raw = try directory.withDescriptor { try openRaw(path, in: $0.rawValue, access, options, permissions) }
        } catch {
            throw (error as? Errno) ?? .badFileDescriptor
        }
        return OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
    }

    /// A close-on-exec O_PATH handle (Linux): it names the file without
    /// opening it for I/O. `.noFollow` keeps a final symbolic link itself and
    /// `.directory` requires a directory.
    static func openPath(
        _ path: String, in directory: borrowing OwnedFileDescriptor, options: FileDescriptor.OpenOptions = []
    ) throws(Errno) -> OwnedFileDescriptor {
        let raw: Int32
        do {
            raw = try directory.withDescriptor { try openPathRaw(path, in: $0.rawValue, options) }
        } catch {
            throw (error as? Errno) ?? .badFileDescriptor
        }
        return OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
    }

    /// `openPath` relative to the current directory.
    static func openPath(_ path: String, options: FileDescriptor.OpenOptions = []) throws(Errno) -> OwnedFileDescriptor {
        OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: try openPathRaw(path, in: AT_FDCWD, options)))
    }

    private static func openPathRaw(_ path: String, in directory: Int32, _ options: FileDescriptor.OpenOptions) throws(Errno) -> Int32 {
        #if os(Linux)
        let raw = unsafe linux_open_path(directory, path, options.rawValue)
        guard raw >= 0 else { throw .current }
        return raw
        #else
        throw .noFunction
        #endif
    }

    private static func openRaw(
        _ path: String, in directory: Int32, _ access: FileDescriptor.AccessMode,
        _ options: FileDescriptor.OpenOptions, _ permissions: FilePermissions
    ) throws(Errno) -> Int32 {
        let flags = access.rawValue | options.rawValue | O_CLOEXEC
        let raw = unsafe openat(directory, path, flags, mode_t(permissions.rawValue))
        guard raw >= 0 else { throw .current }
        return raw
    }

    /// mkdirat(2).
    static func makeDirectory(_ path: String, in directory: FileDescriptor? = nil, permissions: FilePermissions) throws(Errno) {
        guard unsafe mkdirat(directory?.rawValue ?? AT_FDCWD, path, mode_t(permissions.rawValue)) == 0 else { throw .current }
    }

    /// unlinkat(2), with AT_REMOVEDIR for an empty directory.
    static func remove(_ path: String, in directory: FileDescriptor? = nil, isDirectory: Bool = false) throws(Errno) {
        guard unsafe unlinkat(directory?.rawValue ?? AT_FDCWD, path, isDirectory ? AT_REMOVEDIR : 0) == 0 else { throw .current }
    }

    /// renameat(2) within one directory.
    static func rename(_ source: String, to destination: String, in directory: FileDescriptor? = nil) throws(Errno) {
        let directory = directory?.rawValue ?? AT_FDCWD
        guard unsafe renameat(directory, source, directory, destination) == 0 else { throw .current }
    }

    /// fsync(2).
    static func synchronize(_ descriptor: FileDescriptor) throws(Errno) {
        guard fsync(descriptor.rawValue) == 0 else { throw .current }
    }

    /// realpath(3): the absolute path with every symbolic link resolved.
    static func resolvedPath(_ path: FilePath) throws(Errno) -> FilePath {
        // errno is captured before leaving the C string's scope.
        let result: Result<FilePath, Errno> = unsafe path.withPlatformString { input in
            guard let output = unsafe realpath(input, nil) else { return .failure(.current) }
            defer { unsafe free(output) }
            return .success(unsafe FilePath(platformString: output))
        }
        return try result.get()
    }

    /// Whether the open file is on a cgroup v2 filesystem (fstatfs(2) reports
    /// CGROUP2_SUPER_MAGIC from <linux/magic.h>); always false off Linux.
    static func isOnCgroup2(_ descriptor: FileDescriptor) throws(Errno) -> Bool {
        var status = statfs()
        guard unsafe fstatfs(descriptor.rawValue, &status) == 0 else { throw .current }
        #if os(Linux)
        return UInt64(truncatingIfNeeded: status.f_type) == 0x6367_7270
        #else
        return false
        #endif
    }

    /// fcntl(F_GETFD): the descriptor flags, or nil when it is not open.
    static func descriptorFlags(_ descriptor: Int32) -> Int32? {
        let value = libcGetDescriptorFlags(descriptor)
        return value < 0 ? nil : value
    }

    /// FD_CLOEXEC in `descriptorFlags`.
    static let closeOnExecFlag = FD_CLOEXEC

    enum LockMode {
        case shared, exclusive
    }

    /// flock(2) without waiting; `EWOULDBLOCK` while another description holds it.
    static func lock(_ descriptor: FileDescriptor, _ mode: LockMode) throws(Errno) {
        guard flock(descriptor.rawValue, (mode == .shared ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 else { throw .current }
    }

    /// Releases this description's flock.
    static func unlock(_ descriptor: FileDescriptor) {
        _ = flock(descriptor.rawValue, LOCK_UN)
    }
}

/// fcntl is variadic in C; the libc overlay's fixed form is reached here.
private func libcGetDescriptorFlags(_ descriptor: Int32) -> Int32 { fcntl(descriptor, F_GETFD) }
