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
        let resolved: FilePath? = unsafe path.withPlatformString { input in
            guard let output = unsafe realpath(input, nil) else { return nil }
            defer { unsafe free(output) }
            return unsafe FilePath(platformString: output)
        }
        guard let resolved else { throw .current }
        return resolved
    }

    /// CGROUP2_SUPER_MAGIC from <linux/magic.h>.
    static let cgroup2FilesystemType: UInt64 = 0x6367_7270

    /// fstatfs(2)'s filesystem type (`f_type`), such as a magic number.
    static func filesystemType(of descriptor: FileDescriptor) throws(Errno) -> UInt64 {
        var status = statfs()
        guard unsafe fstatfs(descriptor.rawValue, &status) == 0 else { throw .current }
        return UInt64(truncatingIfNeeded: status.f_type)
    }

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
