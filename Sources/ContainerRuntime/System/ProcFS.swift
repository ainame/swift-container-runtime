#if os(Linux)
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
        func identity(_ path: String) throws -> FileIdentity? {
            do {
                return try Kernel.File.status(atPath: path).identity
            } catch where error == .noSuchFileOrDirectory || error == .noSuchProcess {
                return nil
            } catch {
                throw RuntimeError("stat \(path): \(error)")
            }
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
        do {
            let tasks = OwnedFileDescriptor(takingOwnershipOf: try FileDescriptor.open(
                FilePath("/proc/self/task"), .readOnly, options: [.directory, .closeOnExec]))
            // Each entry is one thread, named by its decimal TID.
            return try tasks.directoryEntries().count
        } catch {
            throw RuntimeError.launch(.inspectThreads, (error as? Errno) ?? .ioError)
        }
    }
}
extension ProcFS {
    /// The highest capability number the running kernel supports.
    static func lastCapability() throws -> Int {
        let path = "/proc/sys/kernel/cap_last_cap"
        let bytes: [UInt8]?
        do { bytes = try ProcFS.read(path) } catch { throw RuntimeError("read \(path): \(error)") }
        guard let bytes else { throw RuntimeError("read \(path): file does not exist") }
        return try ProcessCapabilities.parseLastCapability(bytes)
    }
}
#endif
