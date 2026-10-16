#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import LinuxAPI

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
    // libc returns a NUL-terminated error message, copied before another call.
    let message = unsafe String(cString: strerror(code))
    return RuntimeError("\(stage.description): \(message) (errno \(code))")
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

private func reportFailure(_ fd: Int32, _ stage: LaunchStage) -> Never {
    var failure = LaunchFailure(stage: stage.rawValue, code: errno)
    // The message fits PIPE_BUF. EINTR is retried without formatting errors in
    // the child; only the original parent constructs a diagnostic string.
    withUnsafeBytes(of: &failure) { bytes in
        var result: Int
        repeat { result = unsafe write(fd, bytes.baseAddress!, bytes.count) }
        while result < 0 && errno == EINTR
    }
    _exit(125)
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
    guard try launchThreadCount() == 1 else {
        throw RuntimeError("namespace launch requires a single-threaded process; use the synchronous CLI before starting background work")
    }
    var channel: InlineArray<2, Int32> = [0, 0]
    let opened: Int32
    do {
        var descriptors = channel.mutableSpan
        opened = descriptors.withUnsafeMutableBufferPointer {
            unsafe pipe2($0.baseAddress!, O_CLOEXEC)
        }
    }
    guard opened == 0 else { throw launchError(.pipe) }
    let readEnd = channel[0]
    let writeEnd = channel[1]
    let hostnameLength = unsafe strlen(hostname)
    let supervisor = getpid()
    let launcher = fork()
    guard launcher >= 0 else {
        let error = launchError(.forkLauncher)
        _ = close(readEnd); _ = close(writeEnd)
        throw error
    }
    if launcher == 0 {
        _ = close(readEnd)
        guard linux_set_parent_death_signal(SIGKILL) == 0 else { reportFailure(writeEnd, .parentLifetime) }
        guard getppid() == supervisor else { _exit(125) }
        guard unshare(Int32(CLONE_NEWUTS | CLONE_NEWPID | CLONE_NEWNS)) == 0 else {
            reportFailure(writeEnd, .namespaces)
        }
        guard unsafe mount(nil, "/", nil, UInt(MS_REC | MS_PRIVATE), nil) == 0 else {
            reportFailure(writeEnd, .propagation)
        }
        // PID 1 sees getppid()==0 because its parent is outside its namespace.
        // The inherited pidfd detects parent death before PDEATHSIG is set.
        let parentFD = linux_pidfd_open(getpid())
        guard parentFD >= 0 else { reportFailure(writeEnd, .parentLifetime) }
        let child = fork()
        guard child >= 0 else { reportFailure(writeEnd, .forkInit) }
        if child == 0 {
            guard linux_set_parent_death_signal(SIGKILL) == 0 else { reportFailure(writeEnd, .parentLifetime) }
            var parent = pollfd(fd: parentFD, events: Int16(POLLIN), revents: 0)
            var ready: Int32
            repeat { ready = unsafe poll(&parent, 1, 0) } while ready < 0 && errno == EINTR
            guard ready >= 0 else { reportFailure(writeEnd, .parentLifetime) }
            guard ready == 0 else { _exit(125) }
            _ = close(parentFD)
            guard unsafe mount("proc", "/proc", "proc", UInt(MS_NOSUID | MS_NODEV | MS_NOEXEC), nil) == 0 else {
                reportFailure(writeEnd, .procMount)
            }
            guard unsafe sethostname(hostname, hostnameLength) == 0 else { reportFailure(writeEnd, .hostname) }
            _ = unsafe execv(arguments[0]!, arguments)
            reportFailure(writeEnd, .execute)
        }
        _ = close(parentFD); _ = close(writeEnd)
        guard let status = waitStatus(child) else { _exit(125) }
        _exit(shellStatus(status))
    }
    _ = close(writeEnd)
    var failure = LaunchFailure()
    let readError: Int32? = withUnsafeMutableBytes(of: &failure) { bytes in
        var received = 0
        while received < bytes.count {
            let count = unsafe read(readEnd, bytes.baseAddress!.advanced(by: received), bytes.count - received)
            if count < 0 && errno == EINTR { continue }
            if count < 0 { return errno }
            if count == 0 { return received == 0 ? nil : EIO }
            received += count
        }
        return nil
    }
    _ = close(readEnd)
    guard let status = waitStatus(launcher) else { throw launchError(.wait) }
    if let readError { throw launchError(.protocolRead, readError) }
    if failure.stage != 0 {
        throw launchError(LaunchStage(rawValue: failure.stage) ?? .protocolRead, failure.code)
    }
    return shellStatus(status)
}
#endif
