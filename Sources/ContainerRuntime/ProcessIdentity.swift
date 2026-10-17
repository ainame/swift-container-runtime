#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import LinuxAPI
import SystemPackage

/// Reads a small procfs file; nil when it does not exist (or the process
/// it describes has gone).
func readProcFile(_ path: String, limit: Int = 4096) throws -> [UInt8]? {
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
func currentBootID() throws -> String {
    guard let bytes = try readProcFile("/proc/sys/kernel/random/boot_id") else {
        throw RuntimeError("read /proc/sys/kernel/random/boot_id: file does not exist")
    }
    let text = String(decoding: bytes, as: UTF8.self)
    let trimmed = text.hasSuffix("\n") ? String(text.dropLast()) : text
    guard isValidBootID(trimmed) else { throw RuntimeError("unexpected kernel boot ID \(trimmed)") }
    return trimmed
}

/// `/proc/<pid>/stat`, or nil when the process no longer exists.
func processStat(_ pid: pid_t) throws -> ProcessStat? {
    guard let bytes = try readProcFile("/proc/\(pid)/stat") else { return nil }
    guard let stat = ProcessStat(parsing: bytes) else {
        throw RuntimeError("cannot parse /proc/\(pid)/stat")
    }
    return stat
}

/// The identity of a process the caller has already pinned (an unreaped
/// child, or one held by a pidfd and still running).
func processIdentity(of pid: pid_t) throws -> InitIdentity {
    guard let stat = try processStat(pid) else {
        throw RuntimeError("container init \(pid) exited before its identity was recorded")
    }
    return InitIdentity(pid: pid, startTime: stat.startTime, bootID: try currentBootID())
}

/// Whether `pid` is in the caller's PID namespace.
private func sharesPIDNamespace(_ pid: pid_t) throws -> Bool {
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

/// Polls with a monotonic deadline, so interruption cannot restart the full
/// timeout. A zero result means timeout or an invalid/unusable descriptor.
func pollEvents(
    _ owner: borrowing OwnedFileDescriptor, events: Int16, milliseconds: Int32
) -> Int16 {
    func now() -> Int64? {
        var value = timespec()
        guard unsafe clock_gettime(CLOCK_MONOTONIC, &value) == 0 else { return nil }
        return Int64(value.tv_sec) * 1_000 + Int64(value.tv_nsec) / 1_000_000
    }
    guard let started = now() else { return 0 }
    let deadline = started + Int64(max(0, milliseconds))

    // Keep ownership through every retry and recompute only the remaining wait.
    return (try? owner.withDescriptor { descriptor -> Int16 in
        while true {
            guard let current = now() else { return 0 }
            let remaining = Int32(max(0, min(Int64(Int32.max), deadline - current)))
            var target = pollfd(fd: descriptor.rawValue, events: events, revents: 0)
            let result = unsafe poll(&target, 1, remaining)
            if result > 0 { return target.revents & Int16(POLLNVAL) == 0 ? target.revents : 0 }
            if result == 0 || errno != EINTR { return 0 }
            guard let resumed = now(), resumed < deadline else { return 0 }
        }
    }) ?? 0
}

/// Waits up to `milliseconds` for the process behind a pidfd to exit.
func waitForExit(_ pidfd: borrowing OwnedFileDescriptor, milliseconds: Int32) -> Bool {
    pollEvents(pidfd, events: Int16(POLLIN), milliseconds: milliseconds) & Int16(POLLIN | POLLHUP) != 0
}

/// A process pinned by a pidfd after its identity was verified.
struct ProcessHandle: ~Copyable {
    let pid: pid_t
    let descriptor: OwnedFileDescriptor

    /// Sends `signal` through the pidfd; false if the process has exited.
    func signal(_ signal: Int32) throws -> Bool {
        let result = try descriptor.withDescriptor { linux_pidfd_send_signal($0.rawValue, signal) }
        if result == 0 { return true }
        if errno == ESRCH { return false }
        throw RuntimeError("signal container init \(pid): \(Errno(rawValue: errno))")
    }

    func waitForExit(milliseconds: Int32) -> Bool {
        ContainerRuntime.waitForExit(descriptor, milliseconds: milliseconds)
    }
}

/// Calls `body` with a pidfd for the recorded init only while that exact
/// process is alive; returns nil otherwise.
///
/// The pidfd is opened before `/proc/<pid>/stat` is checked. If the PID then
/// still has the recorded start time (in the same boot), the pidfd refers to
/// the recorded process, and signals sent through it can never reach a
/// process that later reuses the PID. Malformed state cannot name PID 1, the
/// caller, or (for a container with its own PID namespace) a process in the
/// caller's PID namespace.
func withVerifiedProcess<Result>(
    _ identity: InitIdentity, separatePIDNamespace: Bool,
    _ body: (borrowing ProcessHandle) throws -> Result
) throws -> Result? {
    // Reject structurally unsafe identities before opening any kernel handle.
    guard identity.pid > 1, identity.pid != getpid() else { return nil }
    guard try currentBootID() == identity.bootID else { return nil }
    // Pin first, then compare procfs identity; a later PID reuse cannot retarget it.
    let raw = linux_pidfd_open(identity.pid)
    guard raw >= 0 else {
        if errno == ESRCH { return nil }
        throw RuntimeError("pidfd_open \(identity.pid): \(Errno(rawValue: errno)) (requires Linux 5.3+)")
    }
    let handle = ProcessHandle(pid: identity.pid, descriptor: OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw)))
    guard let stat = try processStat(identity.pid), stat.startTime == identity.startTime, !stat.hasExited else {
        return nil
    }
    // Private-PID containers must also be outside the control process namespace.
    if separatePIDNamespace, try sharesPIDNamespace(identity.pid) { return nil }
    return try body(handle)
}
#endif
