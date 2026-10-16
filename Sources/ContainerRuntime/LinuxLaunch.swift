#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import LinuxAPI
import SystemPackage

private enum LaunchStage: Int32 {
    case pipe = 1, forkLauncher, namespaces, propagation, forkInit, procMount
    case hostname, execute, wait, protocolRead, parentLifetime, inspectThreads

    var description: String {
        switch self {
        case .pipe: "create launch pipe"
        case .forkLauncher: "fork launcher"
        case .namespaces: "create namespaces"
        case .propagation: "make mount propagation private"
        case .forkInit: "fork namespace init"
        case .procMount: "mount proc"
        case .hostname: "set hostname"
        case .execute: "exec workload"
        case .wait: "wait for workload"
        case .protocolRead: "read launch result"
        case .parentLifetime: "protect parent lifetime"
        case .inspectThreads: "inspect launch threads"
        }
    }
}

/// An internal, fixed-size protocol shared by forked copies of this executable.
private struct LaunchFailure {
    var stage: Int32 = 0
    var code: Int32 = 0
}

private func launchError(_ stage: LaunchStage, _ code: Int32 = errno) -> RuntimeError {
    let error = Errno(rawValue: code)
    return RuntimeError("\(stage.description): \(error) (errno \(code))")
}

/// The Swift bootstrap requires a single-threaded caller, with no concurrent
/// thread creation or signal handler that introduces background work.
func launchThreadCount() throws -> Int {
    guard let directory = unsafe opendir("/proc/self/task") else {
        throw launchError(.inspectThreads)
    }
    defer { _ = unsafe closedir(directory) }
    var count = 0
    errno = 0
    while let entry = unsafe readdir(directory) {
        // Proc task names are decimal TIDs; ignore '.' and '..'.
        let first = unsafe entry.pointee.d_name.0
        if first >= 48 && first <= 57 { count += 1 }
    }
    guard errno == 0 else { throw launchError(.inspectThreads) }
    return count
}

private func failureStatus(_ owner: borrowing OwnedFileDescriptor, _ stage: LaunchStage) -> Int32 {
    let code = errno
    return (try? owner.withDescriptor { descriptor in
        var failure = LaunchFailure(stage: stage.rawValue, code: code)
        // Keep ownership through the write. A cached raw number alone could
        // outlive its owner on a child path that never returns to Swift.
        withUnsafeBytes(of: &failure) { bytes in
            var result: Int
            repeat { result = unsafe write(descriptor.rawValue, bytes.baseAddress!, bytes.count) }
            while result < 0 && errno == EINTR
        }
        return 125
    }) ?? 125
}

private func waitStatus(_ pid: pid_t) -> Int32? {
    var status: Int32 = 0
    var result: pid_t
    repeat { result = unsafe waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
    return result < 0 ? nil : status
}

private func shellStatus(_ status: Int32) -> Int32 {
    // Linux wait status layout; waitpid is used without WUNTRACED/WCONTINUED.
    let signal = status & 0x7f
    return signal == 0 ? (status >> 8) & 0xff : 128 + signal
}

/// All borrowed buffers remain alive until both launch branches finish. This
/// entry point is private to the synchronous, single-thread-checked Swift path.
@unsafe
func runNamespaceProcess(
    hostname: UnsafePointer<CChar>,
    arguments: UnsafePointer<UnsafeMutablePointer<CChar>?>
) throws -> Int32 {
    let channel: (readEnd: FileDescriptor, writeEnd: FileDescriptor)
    do {
        channel = try FileDescriptor.pipe(options: .closeOnExec)
    } catch {
        throw launchError(.pipe, error.rawValue)
    }
    var readOwner = OwnedFileDescriptor(takingOwnershipOf: channel.readEnd)
    var writeOwner = OwnedFileDescriptor(takingOwnershipOf: channel.writeEnd)
    // Perform library initialization before checking the bootstrap precondition.
    guard try launchThreadCount() == 1 else {
        throw RuntimeError("namespace launch requires a single-threaded process; use the synchronous CLI before starting background work")
    }
    let hostnameLength = unsafe strlen(hostname)
    let supervisor = getpid()
    let launcher = fork()
    guard launcher >= 0 else {
        throw launchError(.forkLauncher)
    }
    if launcher == 0 {
        try? readOwner.close()
        guard linux_set_parent_death_signal(SIGKILL) == 0 else { _exit(failureStatus(writeOwner, .parentLifetime)) }
        guard getppid() == supervisor else { _exit(125) }
        guard unshare(Int32(CLONE_NEWUTS | CLONE_NEWPID | CLONE_NEWNS)) == 0 else {
            _exit(failureStatus(writeOwner, .namespaces))
        }
        guard unsafe mount(nil, "/", nil, UInt(MS_REC | MS_PRIVATE), nil) == 0 else {
            _exit(failureStatus(writeOwner, .propagation))
        }
        // PID 1 sees getppid()==0 because its parent is outside its namespace.
        // The inherited pidfd detects parent death before PDEATHSIG is set.
        let parentRawFD = linux_pidfd_open(getpid())
        guard parentRawFD >= 0 else { _exit(failureStatus(writeOwner, .parentLifetime)) }
        var parentOwner = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: parentRawFD))
        let child = fork()
        guard child >= 0 else { _exit(failureStatus(writeOwner, .forkInit)) }
        if child == 0 {
            guard linux_set_parent_death_signal(SIGKILL) == 0 else { _exit(failureStatus(writeOwner, .parentLifetime)) }
            guard let ready = try? parentOwner.withDescriptor({ descriptor in
                var parent = pollfd(fd: descriptor.rawValue, events: Int16(POLLIN), revents: 0)
                var result: Int32
                repeat { result = unsafe poll(&parent, 1, 0) } while result < 0 && errno == EINTR
                return result
            }) else { _exit(failureStatus(writeOwner, .parentLifetime)) }
            guard ready >= 0 else { _exit(failureStatus(writeOwner, .parentLifetime)) }
            guard ready == 0 else { _exit(125) }
            try? parentOwner.close()
            guard unsafe mount("proc", "/proc", "proc", UInt(MS_NOSUID | MS_NODEV | MS_NOEXEC), nil) == 0 else {
                _exit(failureStatus(writeOwner, .procMount))
            }
            guard unsafe sethostname(hostname, hostnameLength) == 0 else { _exit(failureStatus(writeOwner, .hostname)) }
            _ = unsafe execv(arguments[0]!, arguments)
            _exit(failureStatus(writeOwner, .execute))
        }
        try? parentOwner.close(); try? writeOwner.close()
        guard let status = waitStatus(child) else { _exit(125) }
        _exit(shellStatus(status))
    }
    try? writeOwner.close()
    var failure = LaunchFailure()
    let readError: Int32?
    do {
        readError = try readOwner.withDescriptor { readEnd in
            withUnsafeMutableBytes(of: &failure) { bytes in
                var received = 0
                while received < bytes.count {
                    let count: Int
                    do {
                        count = unsafe try readEnd.read(into: UnsafeMutableRawBufferPointer(rebasing: bytes[received...]))
                    } catch {
                        return (error as? Errno)?.rawValue ?? EIO
                    }
                    if count == 0 { return received == 0 ? nil : EIO }
                    received += count
                }
                return nil
            }
        }
    } catch {
        readError = (error as? Errno)?.rawValue ?? EIO
    }
    try? readOwner.close()
    guard let status = waitStatus(launcher) else { throw launchError(.wait) }
    if let readError { throw launchError(.protocolRead, readError) }
    if failure.stage != 0 {
        throw launchError(LaunchStage(rawValue: failure.stage) ?? .protocolRead, failure.code)
    }
    return shellStatus(status)
}
#endif
