#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import LinuxAPI
import SystemPackage

enum LaunchStage: Int32 {
    case pipe = 1, forkLauncher, namespaces, propagation, forkInit, procMount
    case hostname, execute, wait, protocolRead, parentLifetime, inspectThreads
    case bindRootfs, openRootfs, resolveMount, mount, devices, pivotRoot, cwd, verifyRootfs, markDescriptors
    case pinInit, commit, startRequest, startSocket
    case noNewPrivileges, stdioOwnership, supplementaryGroups, setGroupID, setUserID
    case dropBoundingCapability, keepCapabilities, setCapabilities, clearAmbientCapabilities, raiseAmbientCapability
    case setResourceLimit, startDescriptor, readonlyRoot

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
        case .bindRootfs: "bind mount rootfs"
        case .openRootfs: "open rootfs"
        case .resolveMount: "resolve mount destination"
        case .mount: "mount"
        case .devices: "create /dev entries"
        case .pivotRoot: "pivot_root"
        case .cwd: "change to process.cwd"
        case .verifyRootfs: "verify rootfs was not replaced during setup"
        case .markDescriptors: "mark inherited descriptors close-on-exec (requires Linux 5.11+)"
        case .pinInit: "pin container init with a pidfd"
        case .commit: "release prepared container init"
        case .startRequest: "accept start request"
        case .startSocket: "consume start socket"
        case .noNewPrivileges: "set no_new_privs"
        case .stdioOwnership: "give stdio to process.user.uid"
        case .supplementaryGroups: "set process.user.additionalGids"
        case .setGroupID: "set process.user.gid"
        case .setUserID: "set process.user.uid"
        case .dropBoundingCapability: "drop bounding capability"
        case .keepCapabilities: "set PR_SET_KEEPCAPS"
        case .setCapabilities:
            "set effective, permitted, and inheritable capabilities (the runtime must hold every permitted one, and each inheritable one must be in bounding or already inheritable)"
        case .clearAmbientCapabilities: "clear ambient capabilities (requires Linux 4.3+)"
        case .raiseAmbientCapability: "raise ambient capability"
        case .setResourceLimit: "set process.rlimits"
        case .startDescriptor:
            "reserve a descriptor for the start connection (process.rlimits RLIMIT_NOFILE leaves no free descriptor for the created init)"
        case .readonlyRoot: "remount the container root read-only (root.readonly)"
        }
    }
}

/// Fixed-size records sent by forked copies of this executable over the
/// report pipe (or, for a start failure, the start connection). A record is
/// smaller than PIPE_BUF, so each pipe write is atomic.
struct LaunchRecord {
    enum Kind: Int32 {
        /// `accepted`: a created init took a start request and waits for
        /// the start command to commit it (see `StartGate`).
        case failure = 1, initProcess, ready, accepted
    }

    var kind: Int32 = 0
    var stage: Int32 = 0
    var code: Int32 = 0
    /// Stage-specific context, such as a mount index; -1 when unused.
    var detail: Int32 = -1
    /// The init PID in the supervisor's PID namespace, for `initProcess`.
    var value: Int64 = 0

    init() {}

    init(_ kind: Kind, stage: Int32 = 0, code: Int32 = 0, detail: Int32 = -1, value: Int64 = 0) {
        self.kind = kind.rawValue
        self.stage = stage
        self.code = code
        self.detail = detail
        self.value = value
    }
}

func launchError(_ stage: LaunchStage, _ code: Int32 = errno, context: String? = nil) -> RuntimeError {
    let error = Errno(rawValue: code)
    return RuntimeError("\(context ?? stage.description): \(error) (errno \(code))")
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

/// Writes one whole record and reports success. Socket writes use
/// MSG_NOSIGNAL so a vanished peer cannot kill the writer with SIGPIPE.
@discardableResult
func writeRecord(_ owner: borrowing OwnedFileDescriptor, _ record: LaunchRecord, socket: Bool = false) -> Bool {
    (try? owner.withDescriptor { descriptor in
        var record = record
        // Keep ownership through the write. A cached raw number alone could
        // outlive its owner on a child path that never returns to Swift.
        return withUnsafeBytes(of: &record) { bytes in
            var result: Int
            repeat {
                result = unsafe socket
                    ? send(descriptor.rawValue, bytes.baseAddress!, bytes.count, Int32(MSG_NOSIGNAL))
                    : write(descriptor.rawValue, bytes.baseAddress!, bytes.count)
            } while result < 0 && errno == EINTR
            return result == bytes.count
        }
    }) ?? false
}

/// Reports a child-side failure and returns the status to pass to `_exit`.
/// Call as `_exit(failureStatus(...))` or return it from a launch body.
func failureStatus(
    _ owner: borrowing OwnedFileDescriptor, _ stage: LaunchStage, code: Int32 = errno, detail: Int32 = -1,
    socket: Bool = false
) -> Int32 {
    writeRecord(owner, LaunchRecord(.failure, stage: stage.rawValue, code: code, detail: detail), socket: socket)
    return 125
}

enum RecordRead {
    case record(LaunchRecord)
    case end
    case failed(Int32)
}

/// Reads one whole record, or reports EOF before its first byte.
func readRecord(_ owner: borrowing OwnedFileDescriptor) -> RecordRead {
    var record = LaunchRecord()
    let result: Int32?
    do {
        result = try owner.withDescriptor { readEnd in
            withUnsafeMutableBytes(of: &record) { bytes in
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
                return 0
            }
        }
    } catch {
        result = (error as? Errno)?.rawValue ?? EIO
    }
    switch result {
    case nil: return .end
    case 0?: return .record(record)
    case let code?: return .failed(code)
    }
}

/// Blocks until every write end of a pipe is closed.
private func waitForClose(_ owner: borrowing OwnedFileDescriptor) {
    _ = try? owner.withDescriptor { descriptor in
        var byte: UInt8 = 0
        while try withUnsafeMutableBytes(of: &byte, { buffer in unsafe try descriptor.read(into: buffer) }) > 0 {}
    }
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

/// Arms SIGKILL as the parent-death signal of a foreground init, then checks
/// the launcher through its pidfd. Linux clears the signal whenever uid or
/// gid change, so the init calls this again after setting credentials, as
/// runc restores it after finalizeNamespace. The pidfd check closes the race
/// with a launcher that died while no signal was armed: PID 1 of a new PID
/// namespace cannot use getppid. Returns false when the launcher has exited,
/// nil when either step fails.
func restoreParentDeathSignal(_ launcher: borrowing OwnedFileDescriptor) -> Bool? {
    guard linux_set_parent_death_signal(SIGKILL) == 0 else { return nil }
    guard let ready = try? launcher.withDescriptor({ descriptor in
        var parent = pollfd(fd: descriptor.rawValue, events: Int16(POLLIN), revents: 0)
        var result: Int32
        repeat { result = unsafe poll(&parent, 1, 0) } while result < 0 && errno == EINTR
        return result
    }), ready >= 0 else { return nil }
    return ready == 0
}

/// Supervisor-side configuration of a launch. Every closure runs in the
/// calling process except `closeInChildren`.
struct LaunchHooks {
    /// The init waits after setup for a commit instead of executing, has no
    /// parent-death signal, starts a new session, and outlives the launcher
    /// and this process. Used by `create` and detached `run`.
    var detached = false
    /// Runs first in the forked launcher to close inherited descriptors that
    /// must not outlive the supervisor, such as the container lock.
    var closeInChildren: () -> Void = {}
    /// The init is pinned by a pidfd while it is still an unreaped child, so
    /// this identity names it rather than a reused PID.
    var initStarted: (InitIdentity) throws -> Void = { _ in }
    /// Detached only: setup finished; runs before the commit releases the init.
    var ready: () throws -> Void = {}
    /// Foreground only: the workload `execve` succeeded.
    var executed: () throws -> Void = {}
}

/// Forks a launcher that unshares `namespaceFlags` with private mount
/// propagation, then forks the namespace init. The init runs `initialize`
/// with the report pipe, the commit socket, and (in the foreground only) a
/// pidfd for the launcher, which `restoreParentDeathSignal` needs after a
/// credential change; it must exec or return a status from `failureStatus`.
///
/// The launcher reports the init PID and waits until the supervisor has
/// pinned it with a pidfd. In the foreground the launcher then waits for the
/// init, and both die with their parent (PR_SET_PDEATHSIG). Detached, the
/// launcher exits and the init is reparented to the nearest subreaper; until
/// the supervisor commits, EOF on the commit socket tells it to exit.
/// Every failure after the init exists kills it through the pidfd.
///
/// `initialize` runs in a forked child of a single-threaded process. Any
/// buffers it borrows must stay alive until this function returns.
@unsafe
func runLaunch(
    namespaceFlags: Int32,
    hooks: LaunchHooks = LaunchHooks(),
    context: (LaunchStage, Int32) -> String? = { _, _ in nil },
    initialize: (
        _ report: borrowing OwnedFileDescriptor, _ commit: borrowing OwnedFileDescriptor,
        _ launcher: borrowing OwnedFileDescriptor
    ) -> Int32
) throws -> Int32 {
    func makePipe() throws -> (readEnd: FileDescriptor, writeEnd: FileDescriptor) {
        do {
            return try FileDescriptor.pipe(options: .closeOnExec)
        } catch {
            throw launchError(.pipe, error.rawValue)
        }
    }
    let report = try makePipe()
    var reportRead = OwnedFileDescriptor(takingOwnershipOf: report.readEnd)
    var reportWrite = OwnedFileDescriptor(takingOwnershipOf: report.writeEnd)
    let release = try makePipe()
    var releaseRead = OwnedFileDescriptor(takingOwnershipOf: release.readEnd)
    var releaseWrite = OwnedFileDescriptor(takingOwnershipOf: release.writeEnd)
    // A socket rather than a pipe: the commit is sent with MSG_NOSIGNAL, so a
    // vanished init cannot raise SIGPIPE in the supervisor.
    var commitPair: [Int32] = [-1, -1]
    guard unsafe linux_unix_stream_socketpair(&commitPair) == 0 else { throw launchError(.pipe) }
    var commitWrite = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: commitPair[0]))
    var commitRead = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: commitPair[1]))
    // Perform library initialization before checking the bootstrap precondition.
    guard try launchThreadCount() == 1 else {
        throw RuntimeError("namespace launch requires a single-threaded process; use the synchronous CLI before starting background work")
    }
    let supervisor = getpid()
    let launcher = fork()
    guard launcher >= 0 else {
        throw launchError(.forkLauncher)
    }
    if launcher == 0 {
        hooks.closeInChildren()
        try? reportRead.close(); try? releaseWrite.close(); try? commitWrite.close()
        guard linux_set_parent_death_signal(SIGKILL) == 0 else { _exit(failureStatus(reportWrite, .parentLifetime)) }
        guard getppid() == supervisor else { _exit(125) }
        guard unshare(namespaceFlags) == 0 else {
            _exit(failureStatus(reportWrite, .namespaces))
        }
        guard unsafe mount(nil, "/", nil, UInt(MS_REC | MS_PRIVATE), nil) == 0 else {
            _exit(failureStatus(reportWrite, .propagation))
        }
        // PID 1 sees getppid()==0 because its parent is outside its namespace.
        // The inherited pidfd detects parent death before PDEATHSIG is set.
        let parentRawFD = linux_pidfd_open(getpid())
        guard parentRawFD >= 0 else { _exit(failureStatus(reportWrite, .parentLifetime)) }
        var parentOwner = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: parentRawFD))
        let child = fork()
        guard child >= 0 else { _exit(failureStatus(reportWrite, .forkInit)) }
        if child == 0 {
            try? releaseRead.close()
            if hooks.detached {
                // The init outlives the launcher, so no parent-death signal:
                // EOF on the commit socket covers a supervisor that dies before
                // committing. Like runc's init, leave the caller's session so
                // its terminal job control does not reach the container.
                guard setsid() >= 0 else { _exit(failureStatus(reportWrite, .parentLifetime)) }
                try? parentOwner.close()
            } else {
                // Keep the launcher pidfd (close-on-exec, like every pidfd)
                // for the rearm after credentials change.
                switch restoreParentDeathSignal(parentOwner) {
                case true?: break
                case false?: _exit(125)
                case nil: _exit(failureStatus(reportWrite, .parentLifetime))
                }
            }
            _exit(initialize(reportWrite, commitRead, parentOwner))
        }
        try? parentOwner.close(); try? commitRead.close()
        // Report the init while it is an unreaped child of this launcher: its
        // PID cannot be reused until the supervisor has pinned it with a
        // pidfd and closed the release pipe.
        guard writeRecord(reportWrite, LaunchRecord(.initProcess, value: Int64(child))) else { _exit(125) }
        try? reportWrite.close()
        waitForClose(releaseRead)
        try? releaseRead.close()
        if hooks.detached { _exit(0) }
        guard let status = waitStatus(child) else { _exit(125) }
        _exit(shellStatus(status))
    }
    try? reportWrite.close(); try? releaseRead.close(); try? commitRead.close()

    var pinned = OwnedFileDescriptor()
    var initPID: pid_t = 0
    var failure: LaunchRecord? = nil
    var ready = false
    var thrown: (any Error)? = nil
    reading: while thrown == nil {
        switch readRecord(reportRead) {
        case .end:
            break reading
        case let .failed(code):
            thrown = launchError(.protocolRead, code)
        case let .record(record):
            switch LaunchRecord.Kind(rawValue: record.kind) {
            case .initProcess?:
                guard initPID == 0, record.value > 1, record.value <= Int64(Int32.max) else {
                    thrown = launchError(.protocolRead, EPROTO)
                    continue reading
                }
                initPID = pid_t(record.value)
                let raw = linux_pidfd_open(initPID)
                guard raw >= 0 else {
                    thrown = launchError(.pinInit)
                    continue reading
                }
                pinned = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
                do {
                    let identity = try processIdentity(of: initPID)
                    try? releaseWrite.close()
                    try hooks.initStarted(identity)
                } catch {
                    thrown = error
                }
                if ready { break reading }
            case .failure?:
                if failure == nil { failure = record }
            case .ready?:
                guard hooks.detached, failure == nil else {
                    thrown = launchError(.protocolRead, EPROTO)
                    continue reading
                }
                ready = true
                if initPID != 0 { break reading }
            case .accepted?, nil:
                // `accepted` belongs only to the start connection.
                thrown = launchError(.protocolRead, EPROTO)
            }
        }
    }
    // Never leave the launcher blocked, whatever happened above.
    try? releaseWrite.close()
    try? reportRead.close()

    var succeeded = thrown == nil && failure == nil
    if succeeded && hooks.detached && !ready {
        thrown = RuntimeError("container init exited before completing setup")
        succeeded = false
    }
    if succeeded {
        do {
            if hooks.detached {
                try hooks.ready()
                try sendCommit(commitWrite)
            } else if initPID != 0 {
                try hooks.executed()
            }
        } catch {
            thrown = error
            succeeded = false
        }
    }
    if !succeeded && initPID != 0 {
        // The pidfd names this init even after it exits, so this cannot reach
        // a process that reused its PID.
        _ = try? pinned.withDescriptor { linux_pidfd_send_signal($0.rawValue, SIGKILL) }
        _ = waitForExit(pinned, milliseconds: 10_000)
    }
    // A detached init that has not received the commit byte sees EOF and exits.
    try? commitWrite.close()
    guard let status = waitStatus(launcher) else { throw launchError(.wait) }
    if let thrown { throw thrown }
    if let failure {
        let stage = LaunchStage(rawValue: failure.stage) ?? .protocolRead
        throw launchError(stage, failure.code, context: context(stage, failure.detail))
    }
    return hooks.detached ? 0 : shellStatus(status)
}

/// Sends the one-byte commit that lets a detached init leave setup.
private func sendCommit(_ owner: borrowing OwnedFileDescriptor) throws {
    let sent = try owner.withDescriptor { descriptor in
        var byte: UInt8 = 1
        var result: Int
        repeat { result = unsafe send(descriptor.rawValue, &byte, 1, Int32(MSG_NOSIGNAL)) } while result < 0 && errno == EINTR
        return result
    }
    guard sent == 1 else { throw launchError(.commit) }
}

/// Waits in a detached init for the commit byte. EOF means the supervisor
/// failed or died before recording the container, so the init must exit.
func receiveCommit(_ owner: borrowing OwnedFileDescriptor) -> Bool {
    (try? owner.withDescriptor { descriptor in
        var byte: UInt8 = 0
        let count = try withUnsafeMutableBytes(of: &byte) { buffer in unsafe try descriptor.read(into: buffer) }
        return count == 1 && byte == 1
    }) ?? false
}

/// All borrowed buffers remain alive until both launch branches finish. This
/// entry point is private to the synchronous, single-thread-checked Swift path.
@unsafe
func runNamespaceProcess(
    hostname: UnsafePointer<CChar>,
    arguments: UnsafePointer<UnsafeMutablePointer<CChar>?>
) throws -> Int32 {
    let hostnameLength = unsafe strlen(hostname)
    return unsafe try runLaunch(namespaceFlags: Int32(CLONE_NEWUTS | CLONE_NEWPID | CLONE_NEWNS)) { report, _, _ in
        guard unsafe mount("proc", "/proc", "proc", UInt(MS_NOSUID | MS_NODEV | MS_NOEXEC), nil) == 0 else {
            return failureStatus(report, .procMount)
        }
        guard unsafe sethostname(hostname, hostnameLength) == 0 else { return failureStatus(report, .hostname) }
        _ = unsafe execv(arguments[0]!, arguments)
        return failureStatus(report, .execute)
    }
}
#endif
