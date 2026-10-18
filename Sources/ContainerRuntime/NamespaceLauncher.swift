#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import LinuxAPI
import SystemPackage

/// Supervisor-side configuration of a launch. Every closure runs in the
/// calling process except `closeInChildren`.
struct LaunchHooks {
    /// The init waits after setup for a commit instead of executing, has no
    /// parent-death signal, starts a new session, and outlives the launcher
    /// and this process. Used by `create` and detached `run`.
    var detached = false
    /// Exec detaches its lifetime but confirms exec rather than waiting at a start gate.
    var waitsForReady = true
    /// Runs first in the forked launcher to close inherited descriptors that
    /// must not outlive the supervisor, such as the container lock.
    var closeInChildren: () -> Void = {}
    /// Places the blocked init (by PID) in its cgroup before it may run any
    /// setup. Its PID cannot be reused meanwhile: it is still an unreaped
    /// child of the launcher, which waits on the release socket.
    var placeInit: (pid_t) throws -> Void = { _ in }
    /// The init is pinned by a pidfd while it is still an unreaped child, so
    /// this identity names it rather than a reused PID.
    var initStarted: (InitIdentity) throws -> Void = { _ in }
    /// Detached only: setup finished; runs before the commit releases the init.
    var ready: () throws -> Void = {}
    /// Foreground launches and detached exec (no start gate): the workload
    /// `execve` succeeded; runs before the launch verdict.
    var executed: () throws -> Void = {}
    /// Caller descriptors the workload inherits; everything from
    /// `firstInternal` up is marked close-on-exec in the child.
    var preserved = PreservedDescriptors.none
}

/// Synchronous namespace launch choreography; each fork branch closes its own descriptors.
enum NamespaceLauncher {
    /// Forks a launcher that unshares `namespaceFlags` with private mount
    /// propagation, then forks the namespace init. The init runs `initialize`
    /// with the report pipe, the commit socket, and (in the foreground only) a
    /// pidfd for the launcher, which `restoreParentDeathSignal` needs after a
    /// credential change; it must exec or return a status from `LaunchRecord.reportFailure`.
    ///
    /// The launcher reports the init PID and waits until the supervisor has
    /// pinned it with a pidfd. In the foreground the launcher then waits for the
    /// init, and both die with their parent (PR_SET_PDEATHSIG). Detached, the
    /// launcher remains the init's parent until the supervisor's verdict: after
    /// success it exits and, as with runc, the init is reparented to the
    /// caller's nearest subreaper; after a failure it reaps the killed init.
    /// Until the supervisor commits, EOF on the commit socket tells it to exit.
    /// Every failure after the init exists kills it through the pidfd.
    ///
    /// `initialize` runs in a forked child of a single-threaded process. Any
    /// buffers it borrows must stay alive until this function returns.
    @unsafe
    static func run(
        namespaceFlags: Int32,
        hooks: LaunchHooks = LaunchHooks(),
        context: (LaunchStage, Int32) -> String? = { _, _ in nil },
        prepareLauncher: () -> Errno? = { nil },
        initialize: (
            _ report: borrowing OwnedFileDescriptor, _ commit: borrowing OwnedFileDescriptor,
            _ launcher: borrowing OwnedFileDescriptor
        ) -> Int32
    ) throws -> Int32 {
        func makePipe() throws -> (readEnd: FileDescriptor, writeEnd: FileDescriptor) {
            do {
                return try FileDescriptor.pipe(options: .closeOnExec)
            } catch {
                throw RuntimeError.launch(.pipe, error)
            }
        }
        let report = try makePipe()
        var reportRead = OwnedFileDescriptor(takingOwnershipOf: report.readEnd)
        var reportWrite = OwnedFileDescriptor(takingOwnershipOf: report.writeEnd)
        // Sockets rather than pipes: controls are sent with MSG_NOSIGNAL, so a
        // vanished launcher or init cannot raise SIGPIPE in the supervisor.
        var releasePair: [Int32] = [-1, -1]
        guard unsafe linux_unix_stream_socketpair(&releasePair) == 0 else { throw RuntimeError.launch(.pipe) }
        var releaseWrite = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: releasePair[0]))
        var releaseRead = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: releasePair[1]))
        var commitPair: [Int32] = [-1, -1]
        guard unsafe linux_unix_stream_socketpair(&commitPair) == 0 else { throw RuntimeError.launch(.pipe) }
        var commitWrite = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: commitPair[0]))
        var commitRead = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: commitPair[1]))
        // Perform library initialization before checking the bootstrap precondition.
        guard try ProcFS.threadCount() == 1 else {
            throw RuntimeError("namespace launch requires a single-threaded process; use the synchronous CLI before starting background work")
        }
        // Authoritative check: every runtime descriptor now exists, so none may
        // sit in the preserved range (see `PreservedDescriptors.verify`).
        try hooks.preserved.verify()
        let supervisor = getpid()
        let launcher = fork()
        guard launcher >= 0 else {
            throw RuntimeError.launch(.forkLauncher)
        }
        if launcher == 0 {
            hooks.closeInChildren()
            try? reportRead.close(); try? releaseWrite.close(); try? commitWrite.close()
            guard linux_set_parent_death_signal(SIGKILL) == 0 else { _exit(LaunchRecord.reportFailure(to: reportWrite, at: .parentLifetime)) }
            guard getppid() == supervisor else { _exit(125) }
            if let error = prepareLauncher() {
                _exit(LaunchRecord.reportFailure(to: reportWrite, at: .joinNamespaces, error: error))
            }
            if namespaceFlags != 0 {
                guard unshare(namespaceFlags) == 0 else {
                    _exit(LaunchRecord.reportFailure(to: reportWrite, at: .namespaces))
                }
                guard unsafe mount(nil, "/", nil, UInt(MS_REC | MS_PRIVATE), nil) == 0 else {
                    _exit(LaunchRecord.reportFailure(to: reportWrite, at: .propagation))
                }
            }
            // PID 1 sees getppid()==0 because its parent is outside its namespace.
            // The inherited pidfd detects parent death before PDEATHSIG is set.
            let parentRawFD = linux_pidfd_open(getpid())
            guard parentRawFD >= 0 else { _exit(LaunchRecord.reportFailure(to: reportWrite, at: .parentLifetime)) }
            var parentOwner = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: parentRawFD))
            let child = fork()
            guard child >= 0 else { _exit(LaunchRecord.reportFailure(to: reportWrite, at: .forkInit)) }
            if child == 0 {
                try? releaseRead.close()
                if hooks.detached {
                    // The init outlives the launcher, so no parent-death signal:
                    // EOF on the commit socket covers a supervisor that dies before
                    // committing. Like runc's init, leave the caller's session so
                    // its terminal job control does not reach the container.
                    guard setsid() >= 0 else { _exit(LaunchRecord.reportFailure(to: reportWrite, at: .parentLifetime)) }
                    try? parentOwner.close()
                } else {
                    // Keep the launcher pidfd (close-on-exec, like every pidfd)
                    // for the rearm after credentials change.
                    switch NamespaceLauncher.restoreParentDeathSignal(parentOwner) {
                    case true?: break
                    case false?: _exit(125)
                    case nil: _exit(LaunchRecord.reportFailure(to: reportWrite, at: .parentLifetime))
                    }
                }
                // Run nothing (and fork nothing) before the supervisor has placed
                // this init in the container's cgroup; EOF means it failed or died.
                guard LaunchControl.receive(from:commitRead) == LaunchControl.proceed else { _exit(125) }
                _exit(initialize(reportWrite, commitRead, parentOwner))
            }
            try? parentOwner.close(); try? commitRead.close()
            // Report the init while it is an unreaped child of this launcher: its
            // PID cannot be reused until the supervisor has pinned it with a
            // pidfd and released this launcher.
            guard LaunchRecord(.initProcess, value: Int64(child)).write(to: reportWrite) else { _exit(125) }
            try? reportWrite.close()
            var control = LaunchControl.receive(from:releaseRead)
            if hooks.detached {
                // Stay the parent until the supervisor's verdict, as runc stays
                // the parent of its init. EOF after the release: the launch
                // succeeded and, like runc, leaves the child to the caller's
                // nearest subreaper. An abandon: the supervisor killed the child
                // through its pidfd, so reap it here rather than leave a zombie.
                if control == .proceed { control = LaunchControl.receive(from:releaseRead) }
                guard control == .abandon else { _exit(0) }
                _ = wait(child)
                _exit(125)
            }
            try? releaseRead.close()
            guard let status = wait(child) else { _exit(125) }
            _exit(exitCode(status))
        }
        try? reportWrite.close(); try? releaseRead.close(); try? commitRead.close()

        var pinned = OwnedFileDescriptor()
        var initPID: pid_t = 0
        var failure: LaunchRecord? = nil
        var ready = false
        var thrown: (any Error)? = nil
        reading: while thrown == nil {
            switch LaunchRecord.read(from: reportRead) {
            case .end:
                break reading
            case let .failed(error):
                thrown = RuntimeError.launch(.protocolRead, error)
            case let .record(record):
                switch LaunchRecord.Kind(rawValue: record.kind) {
                case .initProcess?:
                    guard initPID == 0, record.value > 1, record.value <= Int64(Int32.max) else {
                        thrown = RuntimeError.launch(.protocolRead, .protocolError)
                        continue reading
                    }
                    initPID = pid_t(record.value)
                    let raw = linux_pidfd_open(initPID)
                    guard raw >= 0 else {
                        thrown = RuntimeError.launch(.pinInit)
                        continue reading
                    }
                    pinned = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
                    do {
                        let identity = try ProcFS.identity(of: initPID)
                        // Join the cgroup while the PID is still held by the
                        // blocked launcher, then let the launcher continue.
                        try hooks.placeInit(initPID)
                        try LaunchControl.proceed.send(over: releaseWrite)
                        try hooks.initStarted(identity)
                        try LaunchControl.proceed.send(over: commitWrite)
                    } catch {
                        thrown = error
                    }
                    if ready { break reading }
                case .failure?:
                    if failure == nil { failure = record }
                case .ready?:
                    guard hooks.detached, failure == nil else {
                        thrown = RuntimeError.launch(.protocolRead, .protocolError)
                        continue reading
                    }
                    ready = true
                    if initPID != 0 { break reading }
                case .accepted?, nil:
                    // `accepted` belongs only to the start connection.
                    thrown = RuntimeError.launch(.protocolRead, .protocolError)
                }
            }
        }
        // The release socket stays open for the launch verdict below.
        try? reportRead.close()

        var succeeded = thrown == nil && failure == nil
        if succeeded && hooks.detached && hooks.waitsForReady && !ready {
            thrown = RuntimeError("container init exited before completing setup")
            succeeded = false
        }
        if succeeded {
            do {
                if hooks.detached && hooks.waitsForReady {
                    try hooks.ready()
                    try LaunchControl.commit.send(over: commitWrite)
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
            _ = pinned.poll(events: Int16(POLLIN), milliseconds: 10_000)
        }
        // A detached launcher still parents the child: after a failure it reaps
        // it, after success it exits on EOF. Never leave the launcher blocked.
        if !succeeded { try? LaunchControl.abandon.send(over: releaseWrite) }
        try? releaseWrite.close()
        // A detached init that has not received the commit byte sees EOF and exits.
        try? commitWrite.close()
        guard let status = wait(launcher) else { throw RuntimeError.launch(.wait) }
        if let thrown { throw thrown }
        if let failure {
            let stage = LaunchStage(rawValue: failure.stage) ?? .protocolRead
            throw RuntimeError.launch(stage, failure.error, context: context(stage, failure.detail))
        }
        return hooks.detached ? 0 : exitCode(status)
    }

    private static func wait(_ pid: pid_t) -> Int32? {
        var status: Int32 = 0
        var result: pid_t
        repeat { result = unsafe waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
        return result < 0 ? nil : status
    }

    private static func exitCode(_ status: Int32) -> Int32 {
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
    static func restoreParentDeathSignal(_ launcher: borrowing OwnedFileDescriptor) -> Bool? {
        guard linux_set_parent_death_signal(SIGKILL) == 0 else { return nil }
        guard let ready = try? launcher.withDescriptor({ descriptor in
            var parent = pollfd(fd: descriptor.rawValue, events: Int16(POLLIN), revents: 0)
            var result: Int32
            repeat { result = unsafe poll(&parent, 1, 0) } while result < 0 && errno == EINTR
            return result
        }), ready >= 0 else { return nil }
        return ready == 0
    }
}
#endif
