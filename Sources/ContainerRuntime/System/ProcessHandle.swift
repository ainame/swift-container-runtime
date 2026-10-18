#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import LinuxAPI
import SystemPackage

/// A process pinned by a pidfd after its identity was verified.
struct ProcessHandle: ~Copyable {
    let pid: pid_t
    let descriptor: OwnedFileDescriptor

    /// Sends `signal` through the pidfd; false if the process has exited.
    func signal(_ signal: Int32) throws -> Bool {
        let result = try descriptor.withDescriptor { linux_pidfd_send_signal($0.rawValue, signal) }
        if result == 0 { return true }
        if errno == ESRCH { return false }
        throw RuntimeError("signal container init \(pid): \(Errno.current)")
    }

    func waitForExit(timeout: Duration) -> Bool {
        descriptor.poll(events: Int16(POLLIN), timeout: timeout) & Int16(POLLIN | POLLHUP) != 0
    }
}

extension ProcessHandle {
    /// Calls `body` with a pidfd for the recorded init only while that exact
    /// process is alive; returns nil otherwise.
    ///
    /// The pidfd is opened before `/proc/<pid>/stat` is checked. If the PID then
    /// still has the recorded start time (in the same boot), the pidfd refers to
    /// the recorded process, and signals sent through it can never reach a
    /// process that later reuses the PID. Malformed state cannot name PID 1, the
    /// caller, or (for a container with its own PID namespace) a process in the
    /// caller's PID namespace.
    static func withVerified<Result>(
        _ identity: InitIdentity, separatePIDNamespace: Bool,
        _ body: (borrowing ProcessHandle) throws -> Result
    ) throws -> Result? {
        // Reject structurally unsafe identities before opening any kernel handle.
        guard identity.pid > 1, identity.pid != getpid() else { return nil }
        guard try ProcFS.bootID() == identity.bootID else { return nil }
        // Pin first, then compare procfs identity; a later PID reuse cannot retarget it.
        let raw = linux_pidfd_open(identity.pid)
        guard raw >= 0 else {
            let error = Errno.current
            if error == .noSuchProcess { return nil }
            // EINVAL also means the PID has no thread-group leader: a reaped
            // init's PID stays allocated while orphaned descendants still use it
            // as their process group or session. Without a pidfd nothing is
            // signalled; procfs only decides whether the recorded init is gone.
            if error == .invalidArgument {
                guard let stat = try ProcFS.processStat(identity.pid), stat.startTime == identity.startTime, !stat.hasExited else {
                    return nil
                }
            }
            throw RuntimeError("pidfd_open \(identity.pid): \(error) (requires Linux 5.3+)")
        }
        let handle = ProcessHandle(pid: identity.pid, descriptor: OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw)))
        guard let stat = try ProcFS.processStat(identity.pid), stat.startTime == identity.startTime, !stat.hasExited else {
            return nil
        }
        // Private-PID containers must also be outside the control process namespace.
        if separatePIDNamespace, try ProcFS.sharesPIDNamespace(identity.pid) { return nil }
        return try body(handle)
    }
}
#endif
