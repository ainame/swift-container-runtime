#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import SystemPackage

/// The device and inode that identify a file while it exists.
struct FileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

/// The fields of stat(2) the runtime compares, in fixed-width types so that
/// platform differences in `dev_t` and `mode_t` stay inside Kernel.
struct FileStatus: Equatable, Sendable {
    let identity: FileIdentity
    let mode: UInt32
    /// The device number of a device node (`st_rdev`).
    let deviceNumber: UInt64
    let owner: UInt32
    let linkCount: UInt64

    fileprivate init(_ status: stat) {
        identity = FileIdentity(
            device: UInt64(truncatingIfNeeded: status.st_dev), inode: UInt64(truncatingIfNeeded: status.st_ino))
        mode = UInt32(truncatingIfNeeded: status.st_mode)
        deviceNumber = UInt64(truncatingIfNeeded: status.st_rdev)
        owner = UInt32(truncatingIfNeeded: status.st_uid)
        linkCount = UInt64(truncatingIfNeeded: status.st_nlink)
    }
}

extension Kernel {
    enum File {
        /// stat(2) of `path`, following symbolic links.
        static func status(atPath path: String) throws(Errno) -> FileStatus {
            var status = stat()
            guard unsafe stat(path, &status) == 0 else { throw .current }
            return FileStatus(status)
        }

        /// fstatat(2) of `name` in `directory`, not following a final symbolic link.
        static func status(of name: String, in directory: FileDescriptor) throws(Errno) -> FileStatus {
            var status = stat()
            guard unsafe fstatat(directory.rawValue, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw .current }
            return FileStatus(status)
        }

        /// fstat(2) of an open descriptor.
        static func status(of descriptor: FileDescriptor) throws(Errno) -> FileStatus {
            var status = stat()
            guard unsafe fstat(descriptor.rawValue, &status) == 0 else { throw .current }
            return FileStatus(status)
        }
    }
}

extension OwnedFileDescriptor {
    /// Device and inode of the open file, or nil if fstat fails.
    func identity() -> FileIdentity? {
        try? withDescriptor { descriptor in try? Kernel.File.status(of: descriptor).identity }
    }

    /// Names in this directory other than `.` and `..`; only subdirectories
    /// (by the entry's type) when `onlyDirectories` is set.
    func directoryEntries(onlyDirectories: Bool = false) throws(Errno) -> [String] {
        let raw: Int32
        do {
            raw = try withDescriptor { unsafe openat($0.rawValue, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        } catch {
            throw (error as? Errno) ?? .badFileDescriptor
        }
        guard raw >= 0 else { throw .current }
        // fdopendir takes ownership of the new descriptor; closedir closes it.
        guard let stream = unsafe fdopendir(raw) else {
            let error = Errno.current
            try? FileDescriptor(rawValue: raw).close()
            throw error
        }
        defer { _ = unsafe closedir(stream) }
        return try unsafe readEntries(onlyDirectories: onlyDirectories) { unsafe readdir(stream) }
    }
}

extension Kernel.File {
    /// Names in the directory at `path` other than `.` and `..`, through one
    /// opendir(3) descriptor (for callers that may have a single free slot).
    static func directoryEntries(atPath path: String, onlyDirectories: Bool = false) throws(Errno) -> [String] {
        guard let stream = unsafe opendir(path) else { throw .current }
        defer { _ = unsafe closedir(stream) }
        return try unsafe readEntries(onlyDirectories: onlyDirectories) { unsafe readdir(stream) }
    }
}

/// Reads a directory stream to its end through `next` (readdir).
private func readEntries(
    onlyDirectories: Bool, _ next: () -> UnsafeMutablePointer<dirent>?
) throws(Errno) -> [String] {
    var names: [String] = []
    while true {
        // readdir signals an error only through errno, and the String work
        // below may change errno, so clear it before every call.
        errno = 0
        guard let entry = unsafe next() else {
            guard errno == 0 else { throw .current }
            return names
        }
        if onlyDirectories, unsafe entry.pointee.d_type != UInt8(DT_DIR) { continue }
        let name = unsafe withUnsafeBytes(of: entry.pointee.d_name) { bytes in
            unsafe String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        if name != "." && name != ".." { names.append(name) }
    }
}
