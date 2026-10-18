#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import LinuxAPI
import SystemPackage

/// Bounded reads and identity information from the running kernel.
enum ProcFS {
    /// Reads a small procfs file; nil when it does not exist (or the process
    /// it describes has gone).
    static func read(_ path: String, limit: Int = 4096) throws -> [UInt8]? {
        let owner: OwnedFileDescriptor
        do {
            owner = OwnedFileDescriptor(takingOwnershipOf: try FileDescriptor.open(FilePath(path), .readOnly, options: .closeOnExec))
        } catch let error as Errno where error == .noSuchFileOrDirectory || error == .noSuchProcess {
            return nil
        }
        do {
            return try owner.readAll(limit: limit)
        } catch let error as Errno where error == .noSuchProcess {
            return nil
        }
    }

    /// The kernel boot ID, which distinguishes start times from different boots.
    static func bootID() throws -> String {
        guard let bytes = try ProcFS.read("/proc/sys/kernel/random/boot_id") else {
            throw RuntimeError("read /proc/sys/kernel/random/boot_id: file does not exist")
        }
        let text = String(decoding: bytes, as: UTF8.self)
        let trimmed = text.hasSuffix("\n") ? String(text.dropLast()) : text
        guard InitIdentity.isValidBootID(trimmed) else { throw RuntimeError("unexpected kernel boot ID \(trimmed)") }
        return trimmed
    }

    /// `/proc/<pid>/stat`, or nil when the process no longer exists.
    static func processStat(_ pid: pid_t) throws -> ProcessStat? {
        guard let bytes = try ProcFS.read("/proc/\(pid)/stat") else { return nil }
        guard let stat = ProcessStat(parsing: bytes) else {
            throw RuntimeError("cannot parse /proc/\(pid)/stat")
        }
        return stat
    }

    /// The identity of a process the caller has already pinned (an unreaped
    /// child, or one held by a pidfd and still running).
    static func identity(of pid: pid_t) throws -> InitIdentity {
        guard let stat = try ProcFS.processStat(pid) else {
            throw RuntimeError("container init \(pid) exited before its identity was recorded")
        }
        return InitIdentity(pid: pid, startTime: stat.startTime, bootID: try ProcFS.bootID())
    }

    /// Whether `pid` is in the caller's PID namespace.
    static func sharesPIDNamespace(_ pid: pid_t) throws -> Bool {
        func identity(_ path: String) throws -> (dev_t, ino_t)? {
            var status = stat()
            guard unsafe stat(path, &status) == 0 else {
                if errno == ENOENT || errno == ESRCH { return nil }
                throw RuntimeError("stat \(path): \(Errno(rawValue: errno))")
            }
            return (status.st_dev, status.st_ino)
        }
        guard let own = try identity("/proc/self/ns/pid"), let other = try identity("/proc/\(pid)/ns/pid") else {
            return false
        }
        return own == other
    }
}
extension ProcFS {
    /// The Swift bootstrap requires a single-threaded caller, with no concurrent
    /// thread creation or signal handler that introduces background work.
    static func threadCount() throws -> Int {
        guard let directory = unsafe opendir("/proc/self/task") else {
            throw RuntimeError.launch(.inspectThreads)
        }
        defer { _ = unsafe closedir(directory) }
        var count = 0
        errno = 0
        while let entry = unsafe readdir(directory) {
            // Proc task names are decimal TIDs; ignore '.' and '..'.
            let first = unsafe entry.pointee.d_name.0
            if first >= 48 && first <= 57 { count += 1 }
        }
        guard errno == 0 else { throw RuntimeError.launch(.inspectThreads) }
        return count
    }
}
#endif
