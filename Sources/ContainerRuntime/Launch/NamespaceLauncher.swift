import SystemPackage

/// Supervisor-side configuration of a launch. Every closure runs in the
/// calling process except `closeInChildren`.
struct LaunchHooks {
    /// The init waits after setup for a commit instead of executing, has no
    /// parent-death signal, starts a new session, and outlives the launcher
    /// and this process. Used by `create` and detached `run`.
    var detached = false
    /// Supervisor writes UID/GID maps while its launcher waits after unshare.
    var mapUserNamespace: ((pid_t) throws -> Void)? = nil
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
    /// prestart and createRuntime hooks, run in the runtime namespace with
    /// the init's PID while the init waits after its mounts. Nil when none.
    var runtimeHooks: ((pid_t) throws -> Void)? = nil
}

/// Synchronous namespace launch choreography; each fork branch closes its own descriptors.
enum NamespaceLauncher {
    /// Forks a launcher that unshares `namespaces` with private mount
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
        unsharing namespaces: [OCIRunPlan.Namespace] = [],
        hooks: LaunchHooks = LaunchHooks(),
        context: (LaunchStage, Int32) -> String? = { _, _ in nil },
        prepareLauncher: () -> LaunchFailure? = { nil },
        initialize: InitBody
    ) throws -> Int32 {
        var channels = try LaunchChannels()
        // Perform library initialization before checking the bootstrap precondition.
        guard try ProcFS.threadCount() == 1 else {
            throw RuntimeError("namespace launch requires a single-threaded process; use the synchronous CLI before starting background work")
        }
        // Authoritative check: every runtime descriptor now exists, so none may
        // sit in the preserved range (see `PreservedDescriptors.verify`).
        try hooks.preserved.verify()
        // Computed before the fork, so the launcher only reads an integer.
        let namespaceFlags = namespaces.reduce(Int32(0)) { $0 | $1.cloneFlag }
        let supervisor = Kernel.Process.id
        let launcher: pid_t
        do { launcher = try Kernel.Process.fork() } catch { throw RuntimeError.launch(.forkLauncher, error) }
        if launcher == 0 {
            runLauncher(
                channels, supervisor: supervisor, namespaceFlags: namespaceFlags, hooks: hooks,
                prepare: prepareLauncher, initialize: initialize)
        }
        return try supervise(&channels, launcher: launcher, hooks: hooks, context: context)
    }

    /// The body run by the init: report, commit and launcher descriptors in,
    /// child exit status out.
    typealias InitBody = (
        _ report: borrowing OwnedFileDescriptor, _ commit: borrowing OwnedFileDescriptor,
        _ launcher: borrowing OwnedFileDescriptor
    ) -> Int32

    /// The forked launcher: joins or creates the namespaces, forks the init and
    /// reports its PID, then waits for the supervisor's verdict (detached) or
    /// for the init itself (foreground).
    private static func runLauncher(
        _ channels: consuming LaunchChannels, supervisor: pid_t, namespaceFlags: Int32, hooks: LaunchHooks,
        prepare: () -> LaunchFailure?, initialize: InitBody
    ) -> Never {
        hooks.closeInChildren()
        try? channels.reportRead.close(); try? channels.releaseWrite.close(); try? channels.commitWrite.close()
        if let error = Errno.failure({ () throws(Errno) in try Kernel.Process.setParentDeathSignal(Kernel.Signal.kill) }) {
            Kernel.Process.exit(LaunchRecord.reportFailure(to: channels.reportWrite, at: .parentLifetime, error: error))
        }
        guard Kernel.Process.parentID == supervisor else { Kernel.Process.exit(125) }

        // Apply process bootstrap settings and enter the namespaces init will start in.
        if let failure = prepare() { Kernel.Process.exit(LaunchRecord.reportFailure(to: channels.reportWrite, failure)) }
        let createsUserNamespace = namespaceFlags & OCIRunPlan.Namespace.user.cloneFlag != 0
        if createsUserNamespace {
            if let error = Errno.failure({ () throws(Errno) in try Kernel.Namespace.unshare(OCIRunPlan.Namespace.user.cloneFlag) }) {
                Kernel.Process.exit(LaunchRecord.reportFailure(to: channels.reportWrite, at: .namespaces, error: error))
            }
            guard LaunchRecord(.userNamespace, value: Int64(Kernel.Process.id)).write(to: channels.reportWrite),
                  LaunchControl.receive(from: channels.releaseRead) == .proceed else { Kernel.Process.exit(125) }
            if let error = Errno.failure({ () throws(Errno) in
                try Kernel.Credentials.setGroupID(0)
                try Kernel.Credentials.setUserID(0)
                // Credential changes clear PDEATHSIG. Re-arm it before the
                // launcher can fork, then close the parent-death race.
                try Kernel.Process.setParentDeathSignal(Kernel.Signal.kill)
            }) { Kernel.Process.exit(LaunchRecord.reportFailure(to: channels.reportWrite, at: .setUserID, error: error)) }
        }
        guard Kernel.Process.parentID == supervisor else { Kernel.Process.exit(125) }
        let remainingFlags = namespaceFlags & ~OCIRunPlan.Namespace.user.cloneFlag
        if remainingFlags != 0 {
            if let error = Errno.failure({ () throws(Errno) in try Kernel.Namespace.unshare(remainingFlags) }) {
                Kernel.Process.exit(LaunchRecord.reportFailure(to: channels.reportWrite, at: .namespaces, error: error))
            }
            if remainingFlags & OCIRunPlan.Namespace.mount.cloneFlag != 0,
               let error = Errno.failure({ () throws(Errno) in
                try unsafe Kernel.Mount.mount(source: nil, target: "/", type: nil, flags: [.recursive, .privatePropagation])
            }) {
                Kernel.Process.exit(LaunchRecord.reportFailure(to: channels.reportWrite, at: .propagation, error: error))
            }
        }

        // PID 1 sees getppid()==0 because its parent is outside its namespace.
        // The inherited pidfd detects parent death before PDEATHSIG is set.
        var launcherPidfd = OwnedFileDescriptor()
        if let error = Errno.failure({ () throws(Errno) in launcherPidfd = try Kernel.Pidfd.open(Kernel.Process.id) }) {
            Kernel.Process.exit(LaunchRecord.reportFailure(to: channels.reportWrite, at: .parentLifetime, error: error))
        }
        let child: pid_t
        do { child = try Kernel.Process.fork() } catch { Kernel.Process.exit(LaunchRecord.reportFailure(to: channels.reportWrite, at: .forkInit, error: error)) }
        if child == 0 {
            runInit(channels, launcher: launcherPidfd, detached: hooks.detached, initialize: initialize)
        }
        try? launcherPidfd.close(); try? channels.commitRead.close()

        // Report the init while it is an unreaped child of this launcher: its
        // PID cannot be reused until the supervisor has pinned it with a
        // pidfd and released this launcher.
        guard LaunchRecord(.initProcess, value: Int64(child)).write(to: channels.reportWrite) else { Kernel.Process.exit(125) }
        try? channels.reportWrite.close()
        var control = LaunchControl.receive(from: channels.releaseRead)
        if hooks.detached {
            // Stay the parent until the supervisor's verdict, as runc stays
            // the parent of its init. EOF after the release: the launch
            // succeeded and, like runc, leaves the child to the caller's
            // nearest subreaper. An abandon: the supervisor killed the child
            // through its pidfd, so reap it here rather than leave a zombie.
            if control == .proceed { control = LaunchControl.receive(from: channels.releaseRead) }
            guard control == .abandon else { Kernel.Process.exit(0) }
            _ = try? Kernel.Process.wait(child)
            Kernel.Process.exit(125)
        }
        try? channels.releaseRead.close()
        guard let status = try? Kernel.Process.wait(child) else { Kernel.Process.exit(125) }
        Kernel.Process.exit(exitCode(status))
    }

    /// The forked init: ties its lifetime to the launcher (foreground) or
    /// leaves the caller's session (detached), waits until the supervisor has
    /// placed it in its cgroup, then runs `initialize`.
    private static func runInit(
        _ channels: consuming LaunchChannels, launcher: consuming OwnedFileDescriptor, detached: Bool, initialize: InitBody
    ) -> Never {
        try? channels.releaseRead.close()
        if detached {
            // The init outlives the launcher, so no parent-death signal:
            // EOF on the commit socket covers a supervisor that dies before
            // committing. Like runc's init, leave the caller's session so
            // its terminal job control does not reach the container.
            if let error = Errno.failure({ () throws(Errno) in try Kernel.Process.startSession() }) {
                Kernel.Process.exit(LaunchRecord.reportFailure(to: channels.reportWrite, at: .parentLifetime, error: error))
            }
            try? launcher.close()
        } else {
            // Keep the launcher pidfd (close-on-exec, like every pidfd)
            // for the rearm after credentials change.
            switch restoreParentDeathSignal(launcher) {
            case true?: break
            case false?: Kernel.Process.exit(125)
            case nil: Kernel.Process.exit(LaunchRecord.reportFailure(to: channels.reportWrite, at: .parentLifetime))
            }
        }
        // Run nothing (and fork nothing) before the supervisor has placed
        // this init in the container's cgroup; EOF means it failed or died.
        guard LaunchControl.receive(from: channels.commitRead) == .proceed else { Kernel.Process.exit(125) }
        Kernel.Process.exit(initialize(channels.reportWrite, channels.commitRead, launcher))
    }

    /// The calling process: follows the reports, then delivers the verdict.
    /// On any failure after the init exists, it is killed through its pidfd.
    private static func supervise(
        _ channels: inout LaunchChannels, launcher: pid_t, hooks: LaunchHooks,
        context: (LaunchStage, Int32) -> String?
    ) throws -> Int32 {
        try? channels.reportWrite.close(); try? channels.releaseRead.close(); try? channels.commitRead.close()
        var progress = LaunchProgress()
        progress.follow(channels, launcher: launcher, hooks: hooks)
        // The release socket stays open for the launch verdict below.
        try? channels.reportRead.close()

        // Decide the verdict and run the hooks that complete a success.
        var thrown = progress.thrown
        var succeeded = thrown == nil && progress.failure == nil
        if succeeded && hooks.detached && hooks.waitsForReady && !progress.ready {
            thrown = RuntimeError("container init exited before completing setup")
            succeeded = false
        }
        if succeeded {
            do {
                if hooks.detached && hooks.waitsForReady {
                    try hooks.ready()
                    try LaunchControl.commit.send(over: channels.commitWrite)
                } else if progress.initPID != 0 {
                    try hooks.executed()
                }
            } catch {
                thrown = error
                succeeded = false
            }
        }

        // Deliver it: a failed init is killed, and neither child is left blocked.
        if !succeeded && progress.initPID != 0 {
            // The pidfd names this init even after it exits, so this cannot reach
            // a process that reused its PID.
            try? progress.pinned.withDescriptor { try Kernel.Pidfd.sendSignal(Kernel.Signal.kill, to: $0) }
            _ = progress.pinned.poll(.input, timeout: .seconds(10))
        }
        // A detached launcher still parents the child: after a failure it reaps
        // it, after success it exits on EOF. Never leave the launcher blocked.
        if !succeeded { try? LaunchControl.abandon.send(over: channels.releaseWrite) }
        try? channels.releaseWrite.close()
        // A detached init that has not received the commit byte sees EOF and exits.
        try? channels.commitWrite.close()
        let status: Int32
        do { status = try Kernel.Process.wait(launcher) } catch { throw RuntimeError.launch(.wait, error) }
        if let thrown { throw thrown }
        if let failure = progress.failure {
            let stage = LaunchStage(rawValue: failure.stage) ?? .protocolRead
            throw RuntimeError.launch(stage, failure.error, context: context(stage, failure.detail), detail: failure.detail)
        }
        return hooks.detached ? 0 : exitCode(status)
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
        guard (try? Kernel.Process.setParentDeathSignal(Kernel.Signal.kill)) != nil else { return nil }
        // A readable pidfd means the launcher has exited.
        let events = launcher.poll(.input, timeout: .zero)
        guard !events.contains(.error) else { return nil }
        return events.isEmpty
    }
}
/// The three channels of a launch, created before the fork; each side closes
/// the ends it does not use right after it.
struct LaunchChannels: ~Copyable {
    /// Launcher and init → supervisor: `LaunchRecord`s.
    var reportRead: OwnedFileDescriptor
    var reportWrite: OwnedFileDescriptor
    /// Supervisor → launcher: the init is placed, then the verdict.
    var releaseWrite: OwnedFileDescriptor
    var releaseRead: OwnedFileDescriptor
    /// Supervisor → init: proceed into setup, then (detached) the commit.
    var commitWrite: OwnedFileDescriptor
    var commitRead: OwnedFileDescriptor

    init() throws {
        let report: (readEnd: FileDescriptor, writeEnd: FileDescriptor)
        do {
            report = try FileDescriptor.pipe(options: .closeOnExec)
        } catch {
            throw RuntimeError.launch(.pipe, error)
        }
        // Owned locals first, so a later failure closes the earlier ends.
        let reportRead = OwnedFileDescriptor(takingOwnershipOf: report.readEnd)
        let reportWrite = OwnedFileDescriptor(takingOwnershipOf: report.writeEnd)
        // Sockets rather than pipes: controls are sent with MSG_NOSIGNAL, so a
        // vanished launcher or init cannot raise SIGPIPE in the supervisor.
        let releasePair: (FileDescriptor, FileDescriptor)
        do { releasePair = try Kernel.Socket.unixStreamPair() } catch { throw RuntimeError.launch(.pipe, error) }
        let releaseWrite = OwnedFileDescriptor(takingOwnershipOf: releasePair.0)
        let releaseRead = OwnedFileDescriptor(takingOwnershipOf: releasePair.1)
        let commitPair: (FileDescriptor, FileDescriptor)
        do { commitPair = try Kernel.Socket.unixStreamPair() } catch { throw RuntimeError.launch(.pipe, error) }
        self.reportRead = reportRead
        self.reportWrite = reportWrite
        self.releaseWrite = releaseWrite
        self.releaseRead = releaseRead
        commitWrite = OwnedFileDescriptor(takingOwnershipOf: commitPair.0)
        commitRead = OwnedFileDescriptor(takingOwnershipOf: commitPair.1)
    }
}

/// What the supervisor has learned from the report pipe.
private struct LaunchProgress: ~Copyable {
    /// The init, pinned once its PID is reported.
    var pinned = OwnedFileDescriptor()
    var initPID: pid_t = 0
    /// The first failure a child reported.
    var failure: LaunchRecord? = nil
    var ready = false
    /// A supervisor-side failure, which ends the reading.
    var thrown: (any Error)? = nil

    /// Reads records until EOF, an error, or (detached) both the init PID and readiness.
    mutating func follow(_ channels: borrowing LaunchChannels, launcher: pid_t, hooks: LaunchHooks) {
        while thrown == nil {
            switch LaunchRecord.read(from: channels.reportRead) {
            case .end:
                return
            case let .failed(error):
                thrown = RuntimeError.launch(.protocolRead, error)
            case let .record(record):
                switch LaunchRecord.Kind(rawValue: record.kind) {
                case .userNamespace?:
                    guard record.value == Int64(launcher), initPID == 0, let map = hooks.mapUserNamespace else {
                        thrown = RuntimeError.launch(.protocolRead, .protocolError)
                        continue
                    }
                    do {
                        try map(launcher)
                        try LaunchControl.proceed.send(over: channels.releaseWrite)
                    } catch { thrown = error }
                case .initProcess?:
                    place(record, channels, hooks: hooks)
                    if ready { return }
                case .failure?:
                    if failure == nil { failure = record }
                case .ready?:
                    guard hooks.detached, failure == nil else {
                        thrown = RuntimeError.launch(.protocolRead, .protocolError)
                        continue
                    }
                    ready = true
                    if initPID != 0 { return }
                case .runtimeHooks?:
                    guard initPID != 0, let run = hooks.runtimeHooks else {
                        thrown = RuntimeError.launch(.protocolRead, .protocolError)
                        continue
                    }
                    // The init resumes only after every hook succeeded.
                    do {
                        try run(initPID)
                        try LaunchControl.proceed.send(over: channels.commitWrite)
                    } catch {
                        thrown = error
                    }
                case .accepted?, nil:
                    // `accepted` belongs only to the start connection.
                    thrown = RuntimeError.launch(.protocolRead, .protocolError)
                }
            }
        }
    }

    /// Pins the reported init, places it in its cgroup while the blocked
    /// launcher still holds its PID, then releases the launcher and the init.
    private mutating func place(_ record: LaunchRecord, _ channels: borrowing LaunchChannels, hooks: LaunchHooks) {
        guard initPID == 0, record.value > 1, record.value <= Int64(Int32.max) else {
            thrown = RuntimeError.launch(.protocolRead, .protocolError)
            return
        }
        initPID = pid_t(record.value)
        do {
            pinned = try Kernel.Pidfd.open(initPID)
        } catch {
            thrown = RuntimeError.launch(.pinInit, error)
            return
        }
        do {
            let identity = try ProcFS.identity(of: initPID)
            try hooks.placeInit(initPID)
            try LaunchControl.proceed.send(over: channels.releaseWrite)
            try hooks.initStarted(identity)
            try LaunchControl.proceed.send(over: channels.commitWrite)
        } catch {
            thrown = error
        }
    }
}
