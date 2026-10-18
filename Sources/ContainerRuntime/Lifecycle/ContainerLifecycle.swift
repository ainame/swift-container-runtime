import SystemPackage

/// Persistent OCI lifecycle commands over one state root, following runc.
///
/// Each container has a directory `<root>/<id>` holding `state.json` (the
/// atomically replaced record) and, while created, `start.sock`. Mutating
/// commands serialize on a per-container `flock`. There is no monitor
/// process: a detached init is reparented to the nearest subreaper (or PID
/// 1), and every command derives the status from the recorded init identity
/// and the live system, so a vanished init reads as stopped.
public struct ContainerLifecycle: Sendable {
    /// The default state root, like runc's `/run/runc`.
    public static let defaultRoot = "/run/swift-container-runtime"

    /// The state root: one subdirectory per container, like runc's `--root`.
    public let root: FilePath

    /// Uses `root` for container state. Nothing is opened or created here;
    /// commands that need the root create it with mode 0700 or require it.
    ///
    /// - Throws: `RuntimeError` when `root` is empty or contains NUL.
    public init(root: String = ContainerLifecycle.defaultRoot) throws {
        guard !root.isEmpty, !root.utf8.contains(0) else {
            throw RuntimeError("--root must be non-empty and contain no NUL")
        }
        self.root = FilePath(root)
    }

    private var usesDefaultRoot: Bool { root == FilePath(Self.defaultRoot) }

    /// runc's `create`: prepares the container (namespaces, cgroup, rootfs,
    /// credentials) and leaves its init waiting for ``start(id:)``. The
    /// workload will inherit this process's stdin, stdout, and stderr.
    ///
    /// - Parameters:
    ///   - id: The new container's ID; no container with it may exist.
    ///   - plan: The validated bundle configuration.
    ///   - pidFile: A path that receives the init's host PID, or nil.
    ///   - preserveDescriptors: How many caller descriptors from 3 up the
    ///     workload inherits, as runc's `--preserve-fds`.
    ///   - pidfdSocket: A Unix socket address that receives the init's pidfd.
    ///   - noNewKeyring: Inherit the caller's session keyring instead of creating a container session.
    ///   - consoleSocket: A Unix socket address that receives the terminal
    ///     master; required exactly when `plan` requests a terminal.
    /// - Throws: ``LifecycleError/alreadyExists(_:)`` for a taken ID, or
    ///   `RuntimeError` for a setup failure; no state is left behind then.
    @available(*, noasync, message: "create containers before starting async work")
    public func create(
        id: ContainerID, plan: OCIRunPlan, pidFile: String? = nil, preserveDescriptors: Int = 0, pidfdSocket: String? = nil,
        noNewKeyring: Bool = false, consoleSocket: String? = nil
    ) throws {
        let preserved = try Self.verifiedPreserved(preserveDescriptors)
        let address = try pidfdSocket.map { try UnixSocketAddress($0) }
        let console = try Self.consoleAddress(consoleSocket, terminal: plan.terminal, detached: true)
        try createOnLinux(
            id: id, plan: plan, start: false, pidFile: pidFile, preserved: preserved, pidfdSocket: address,
            noNewKeyring: noNewKeyring, consoleSocket: console)
    }

    /// runc's `run`: creates and starts a container in one step.
    ///
    /// In the foreground this waits for the workload and then removes the
    /// container's state, unless `keep` is set. Detached, it returns once the
    /// workload has started and leaves the container running.
    ///
    /// - Parameters:
    ///   - id: The new container's ID; no container with it may exist.
    ///   - plan: The validated bundle configuration.
    ///   - detach: Return after the start instead of waiting for the workload.
    ///   - keep: In the foreground, keep the stopped container's state.
    ///   - pidFile: A path that receives the init's host PID, or nil.
    ///   - preserveDescriptors: How many caller descriptors from 3 up the
    ///     workload inherits, as runc's `--preserve-fds`.
    ///   - pidfdSocket: A Unix socket address that receives the init's pidfd.
    ///   - noNewKeyring: Inherit the caller's session keyring instead of creating a container session.
    ///   - consoleSocket: A Unix socket address that receives the terminal
    ///     master; required exactly when a detached `plan` requests a terminal.
    ///     A foreground terminal is not implemented.
    /// - Returns: The workload's shell-style ``ExitStatus``: its exit code
    ///   (0...255), or 128 plus the signal number when a signal killed it.
    ///   Signal interpretation is conventional: an explicit exit code can
    ///   have the same value. Pass ``ExitStatus/shellStatus`` to a CLI's exit
    ///   function. Returns ``ExitStatus/success`` when `detach` is set.
    /// - Throws: ``LifecycleError/alreadyExists(_:)`` for a taken ID, or
    ///   `RuntimeError` when setup fails before the workload starts.
    @available(*, noasync, message: "launch containers before starting async work")
    public func run(
        id: ContainerID, plan: OCIRunPlan, detach: Bool, keep: Bool = false, pidFile: String? = nil,
        preserveDescriptors: Int = 0, pidfdSocket: String? = nil, noNewKeyring: Bool = false, consoleSocket: String? = nil
    ) throws -> ExitStatus {
        let preserved = try Self.verifiedPreserved(preserveDescriptors)
        let address = try pidfdSocket.map { try UnixSocketAddress($0) }
        let console = try Self.consoleAddress(consoleSocket, terminal: plan.terminal, detached: detach)
        if detach {
            try createOnLinux(
                id: id, plan: plan, start: true, pidFile: pidFile, preserved: preserved, pidfdSocket: address,
                noNewKeyring: noNewKeyring, consoleSocket: console)
            return .success
        }
        return ExitStatus(shellStatus: try runForegroundOnLinux(
            id: id, plan: plan, keep: keep, pidFile: pidFile, preserved: preserved, pidfdSocket: address, noNewKeyring: noNewKeyring))
    }

    /// runc's `exec`: runs another process in the namespaces,
    /// root and cgroup of a created or running container. The container's
    /// state and init are unchanged; the overrides apply to this process only.
    ///
    /// - Parameters:
    ///   - id: The container to enter.
    ///   - arguments: The command and its arguments; ignored with `processFile`.
    ///   - environment: `NAME=value` entries added to the process environment.
    ///   - cwd: The working directory inside the container.
    ///   - user: `uid[:gid]` to run as.
    ///   - additionalGids: Supplementary groups appended to the process's.
    ///   - noNewPrivileges: Overrides the process's `noNewPrivileges` when set.
    ///   - capabilities: Capability names added to the process's sets.
    ///   - detach: Return once the process has executed instead of waiting.
    ///   - pidFile: A path that receives the process's host PID, or nil.
    ///   - processFile: An OCI `process` JSON file replacing the command.
    ///   - ignorePaused: Wait for a paused container to resume instead of failing.
    ///   - preserveDescriptors: How many caller descriptors from 3 up the
    ///     process inherits, as runc's `--preserve-fds`.
    ///   - pidfdSocket: A Unix socket address that receives the process's pidfd.
    ///   - terminal: Give a command exec a terminal (runc's `--tty`); a
    ///     process file sets its own `terminal`.
    ///   - consoleSocket: A Unix socket address that receives the terminal
    ///     master; required exactly when a detached exec has a terminal.
    /// - Returns: The workload's shell-style ``ExitStatus``: its exit code
    ///   (0...255), or 128 plus the signal number when a signal killed it.
    ///   Signal interpretation is conventional: an explicit exit code can
    ///   have the same value. Pass ``ExitStatus/shellStatus`` to a CLI's exit
    ///   function. Returns ``ExitStatus/success`` when `detach` is set.
    /// - Throws: ``LifecycleError/notFound(_:)`` for a missing container, or
    ///   `RuntimeError` when it is stopped (or paused, without `ignorePaused`)
    ///   or the process cannot be started.
    @available(*, noasync, message: "exec processes before starting async work")
    public func exec(
        id: ContainerID, arguments: [String], environment: [String] = [],
        cwd: String? = nil, user: String? = nil, additionalGids: [UInt32] = [], noNewPrivileges: Bool? = nil,
        capabilities: [String] = [], detach: Bool = false, pidFile: String? = nil, processFile: String? = nil,
        ignorePaused: Bool = false, preserveDescriptors: Int = 0, pidfdSocket: String? = nil,
        terminal: Bool = false, consoleSocket: String? = nil
    ) throws -> ExitStatus {
        let preserved = try Self.verifiedPreserved(preserveDescriptors)
        let address = try pidfdSocket.map { try UnixSocketAddress($0) }
        // Serialize acquisition with delete/start, then pin the recorded init
        // and all kernel handles before releasing any new child.
        let container = try lock(id)
        var pinned: (process: InitIdentity, cgroup: CgroupIdentity)?
        var target: (record: ContainerRecord, process: InitIdentity, cgroup: CgroupIdentity)?
        while target == nil {
            guard let record = try container.readRecord(), let process = record.initProcess,
                  let cgroup = record.cgroup else { throw RuntimeError("container has no recorded init or cgroup") }
            // After a paused wait, only the generation observed before
            // unlocking may proceed; never follow a replacement container.
            if let pinned, pinned.process != process || pinned.cgroup != cgroup {
                throw RuntimeError("container was replaced while waiting for resume")
            }
            let status = try container.status(of: record)
            switch LifecycleOperation.execAdmission(status: status, ignorePaused: ignorePaused) {
            case .proceed:
                target = (record, process, cgroup)
            case .reject(let message):
                throw RuntimeError(message)
            case .waitForResume:
                // Like kontainer-runtime, wait before forking, so no child joins
                // the frozen cgroup and resume can take the lock meanwhile.
                pinned = (process, cgroup)
                container.unlock()
                try Self.waitForThaw(process, separatePIDNamespace: record.pidNamespace, cgroup: cgroup)
                // Relocking fails if the state directory was deleted or recreated.
                try container.lock()
            }
        }
        guard let target else { throw RuntimeError("container has no recorded init or cgroup") }
        let (record, process, cgroup) = (target.record, target.process, target.cgroup)
        guard processFile?.utf8.contains(0) != true else { throw RuntimeError("process file path contains NUL") }
        let plan = try OCIRunPlan.loadExec(
            bundle: FilePath(record.bundle), arguments: arguments, environment: environment, cwd: cwd, user: user,
            additionalGids: additionalGids, noNewPrivileges: noNewPrivileges, capabilities: capabilities,
            processFile: processFile.map { FilePath($0) }, terminal: terminal)
        let console = try Self.consoleAddress(consoleSocket, terminal: plan.terminal, detached: detach)
        let result = try ProcessHandle.withVerified(process, separatePIDNamespace: record.pidNamespace) { handle in
            let namespaces = try ExecNamespaceSet(process: handle)
            var hooks = LaunchHooks()
            hooks.detached = detach
            hooks.waitsForReady = false
            hooks.preserved = preserved
            hooks.closeInChildren = { container.detachInForkedChild() }
            hooks.placeInit = { try CgroupLeaf.join(cgroup, pid: $0) }
            var child: Int32 = 0
            hooks.initStarted = { child = $0.pid }
            hooks.executed = {
                if let pidFile { try PIDFile.write(child, to: pidFile) }
                // Foreground wait must not block state, kill or deletion.
                container.unlock()
            }
            // Dialled only for an accepted target and plan, just before the
            // fork. As in runc, a relative path resolves in the bundle for
            // command exec and in the caller's directory for --process.
            let pidfd = try address.map {
                try PidfdSocket(connectingTo: $0, relativeTo: processFile == nil ? record.bundle : nil)
            }
            defer { pidfd?.close() }
            let terminalSetup = try console.map {
                try TerminalSetup(
                    connectingTo: $0, relativeTo: processFile == nil ? record.bundle : nil,
                    size: plan.consoleSize, bindsConsole: false)
            }
            defer { terminalSetup?.close() }
            // Security settings come from the record, never the (mutable)
            // bundle; legacy records without a keyring setting keep the
            // caller's session keyring, as they did before.
            let keyring = SessionKeyringSetup(id: id, disabled: record.noNewKeyring ?? true, isExec: true)
            // A process file may override the recorded labels; a command
            // exec rereads the bundle, so only the record applies to it.
            let labels = (record.securityLabels ?? SecurityLabels())
                .overridden(by: processFile == nil ? SecurityLabels() : plan.securityLabels)
            return try plan.execOnLinux(
                namespaces: namespaces, hooks: hooks, pidfdSocket: pidfd, seccomp: record.seccomp,
                oomScoreAdjustment: record.oomScoreAdjustment, keyring: keyring, securityLabels: labels,
                terminal: terminalSetup)
        }
        guard let result else { throw RuntimeError("container init is no longer running") }
        return detach ? .success : ExitStatus(shellStatus: result)
    }

    /// Waits, without the state lock, until the recorded cgroup no longer
    /// requests freezing. Unlike the locked status check this never waits for
    /// freeze completion, which a concurrent resume could make time out. The
    /// caller revalidates under the lock. The pinned init's pidfd doubles as the poll interval,
    /// so a kill or force delete ends the wait promptly with an error.
    private static func waitForThaw(
        _ process: InitIdentity, separatePIDNamespace: Bool, cgroup: CgroupIdentity
    ) throws {
        let thawed = try ProcessHandle.withVerified(process, separatePIDNamespace: separatePIDNamespace) { handle in
            while CgroupLeaf.isFreezeRequested(cgroup) {
                if handle.waitForExit(timeout: .milliseconds(100)) { return false }
            }
            return true
        }
        guard thawed == true else { throw RuntimeError("container init is no longer running") }
    }

    /// runc's `start`: lets a created container's init execute its workload.
    /// Returns once the workload has executed; the start happens exactly once.
    ///
    /// - Throws: ``LifecycleError`` when the container is missing or not in
    ///   the created state, or `RuntimeError` when the exec fails.
    public func start(id: ContainerID) throws {
        let container = try lock(id)
        let record = try container.readRecord()
        _ = try LifecycleOperation.start.action(for: try container.status(of: record), id: id)
        try StartProtocol.start(container)
    }

    /// runc's `pause`: freezes every process of a running container (or of a
    /// created one still waiting for `start`) through the cgroup freezer.
    ///
    /// - Throws: ``LifecycleError`` when the container is missing or in
    ///   another state, or `RuntimeError` when the cgroup cannot be frozen.
    public func pause(id: ContainerID) throws {
        try changeFreezer(id: id, frozen: true)
    }

    /// runc's `resume`: thaws a paused container, which then reads as
    /// running again (or created, when its init is still waiting for `start`).
    ///
    /// - Throws: ``LifecycleError`` when the container is missing or not
    ///   paused, or `RuntimeError` when the cgroup cannot be thawed.
    public func resume(id: ContainerID) throws {
        try changeFreezer(id: id, frozen: false)
    }

    private func changeFreezer(id: ContainerID, frozen: Bool) throws {
        let container = try lock(id)
        let record = try container.readRecord()
        let operation: LifecycleOperation = frozen ? .pause : .resume
        _ = try operation.action(for: try container.status(of: record), id: id)
        guard let identity = record?.cgroup else { throw RuntimeError("container has no recorded cgroup") }
        try CgroupLeaf.setFrozen(identity, frozen: frozen)
    }

    /// runc's `update`: changes the resource limits of a live container and
    /// records them in its state. The kernel writes are not atomic; when one
    /// fails, the earlier ones are rolled back on a best-effort basis, as runc does.
    ///
    /// - Throws: ``LifecycleError`` when the container is missing or stopped,
    ///   or `RuntimeError` when a limit is refused.
    public func update(id: ContainerID, resources: ResourceUpdate) throws {
        let container = try lock(id)
        guard var record = try container.readRecord(), let identity = record.cgroup else {
            throw RuntimeError("container has no recorded cgroup")
        }
        _ = try LifecycleOperation.update.action(for: try container.status(of: record), id: id)
        guard let previous = record.resourceConfiguration else {
            throw RuntimeError("container predates saved resource configuration; recreate it to update resources")
        }
        let merged = resources.merged(with: previous)
        let converted = try CgroupPlan.converted(merged)
        do {
            try CgroupLeaf.update(identity, resources: converted)
        } catch {
            let original = error
            do { try CgroupLeaf.update(identity, resources: CgroupPlan.converted(previous)) }
            catch { RuntimeDiagnostics.writeError("swift-container-runtime: warning: resource rollback failed: \(error)") }
            throw original
        }
        // Persist only after the kernel accepts the new settings. The
        // source bundle may already have been removed or renamed.
        record.resourceConfiguration = merged
        try container.writeRecord(record)
    }

    /// The host PIDs of every process in the container's cgroup and its
    /// descendant cgroups, as a snapshot.
    ///
    /// - Returns: Host process IDs (`pid_t`); empty once the cgroup is gone.
    /// - Throws: ``LifecycleError/notFound(_:)`` for a missing container, or
    ///   `RuntimeError` for one that never recorded a cgroup.
    public func processIDs(id: ContainerID) throws -> [Int32] {
        let container = try lock(id)
        guard let record = try container.readRecord(), let identity = record.cgroup else {
            throw RuntimeError("container has no recorded cgroup")
        }
        return try CgroupLeaf.processes(identity)
    }

    /// runc's `ps`: the host `ps` output (`ps -ef` by default, otherwise
    /// `ps` with `arguments`) filtered to the container's processes, keeping
    /// the header and the caller's column layout.
    ///
    /// - Throws: ``LifecycleError/notFound(_:)`` for a missing container, or
    ///   `RuntimeError` when `ps` fails or prints no PID column.
    public func processTable(id: ContainerID, arguments: [String] = []) throws -> String {
        let pids = try processIDs(id: id)
        return try ProcessTable.filter(ProcessTable.readHost(arguments: arguments), pids: pids)
    }

    /// runc's `state`: the container's OCI state with its live status.
    /// Reads without taking the container lock.
    ///
    /// - Throws: ``LifecycleError/notFound(_:)`` for a missing container.
    public func state(id: ContainerID) throws -> ContainerStateReport {
        guard let root = try StateRoot.open(root, create: false) else { throw LifecycleError.notFound(id) }
        return try snapshot(root, id)
    }

    /// runc's `events`: reports a live container's events through `emit`.
    ///
    /// With `statsOnly`, emits one statistics event and returns. Otherwise
    /// emits statistics every `interval` (the first one interval after the
    /// start) and an OOM event whenever the kernel kills a process for
    /// memory, until the container's cgroup empties or its state is deleted
    /// or recreated. Blocks the calling thread and holds no lock while waiting.
    ///
    /// - Throws: ``LifecycleError/notFound(_:)`` for a missing container,
    ///   `RuntimeError` for a stopped container or a nonpositive `interval`,
    ///   or whatever `emit` throws, which ends the stream.
    @available(*, noasync, message: "events blocks the calling thread while it waits")
    public func events(
        id: ContainerID, interval: Duration, statsOnly: Bool, emit: (ContainerEvent) throws -> Void
    ) throws {
        try eventsOnLinux(id: id, interval: interval, statsOnly: statsOnly, emit: emit)
    }

    /// Sends `signal` to init; SIGKILL also kills its cgroup subtree when the
    /// PID namespace is shared, even if init has exited, as in runc 1.4.
    ///
    /// - Parameters:
    ///   - id: A created, running or paused container.
    ///   - signal: A Linux signal number, such as 15 for SIGTERM; see
    ///     ``SignalName/parse(_:)`` for names. SIGKILL also thaws a paused
    ///     container so that the kill takes effect, as runc does.
    ///   - all: runc's compatibility flag: stopped containers succeed; signals
    ///     other than SIGKILL still target init only.
    /// - Throws: ``LifecycleError`` when the container is missing, stopped, or
    ///   its init has already exited.
    public func kill(id: ContainerID, signal: Int32, all: Bool = false) throws {
        let container = try lock(id)
        let record = try container.readRecord()
        let status = try container.status(of: record)
        // In a private namespace the kernel kills descendants when init dies.
        // Shared namespaces need a cgroup-wide kill, including surviving execs
        // after init exits. State locking serializes this with exec and delete.
        if signal == Kernel.Signal.kill, let record, !record.pidNamespace, let identity = record.cgroup {
            if status == .stopped, !all, try CgroupLeaf.processes(identity).isEmpty {
                throw LifecycleError.invalidTransition(id: id, operation: "kill", status: .stopped)
            }
            if status != .stopped {
                _ = try LifecycleOperation.kill.action(for: status, id: id)
            }
            try CgroupLeaf.killAll(identity)
            try? CgroupLeaf.setFrozen(identity, frozen: false)
            return
        }
        // Modern runc keeps --all as a compatibility flag, not a request to
        // broadcast non-KILL signals. Missing containers still fail in lock().
        if all, status == .stopped { return }
        _ = try LifecycleOperation.kill.action(for: status, id: id)
        guard let record, let process = record.initProcess,
              try ProcessHandle.withVerified(process, separatePIDNamespace: record.pidNamespace, { try $0.signal(signal) }) == true else {
            throw LifecycleError.invalidTransition(id: id, operation: "kill", status: .stopped)
        }
        if signal == Kernel.Signal.kill, let identity = record.cgroup {
            try? CgroupLeaf.setFrozen(identity, frozen: false)
        }
    }

    /// runc's `delete`: removes a stopped container's state and cgroup.
    ///
    /// A created container's waiting init is killed first, as in runc. A
    /// running or paused one requires `force`, which sends SIGKILL and waits
    /// up to 10 seconds for the init to exit.
    ///
    /// - Throws: ``LifecycleError`` when the container is missing (unless
    ///   `force` is set, which then succeeds as in runc) or running without
    ///   `force`; `RuntimeError` when the init outlives SIGKILL.
    public func delete(id: ContainerID, force: Bool) throws {
        let container: LockedContainer
        do {
            container = try lock(id)
        } catch LifecycleError.notFound(_) where force {
            return
        }
        // Derive the operation from the verified live state while serialized.
        let record = try container.readRecord()
        let action = try LifecycleOperation.delete(force: force).action(for: try container.status(of: record), id: id)
        // A created init must also be stopped before its gate is removed.
        if action != .destroy, try !Self.killInit(record) {
            throw RuntimeError("container \(id.rawValue) init is still running 10 seconds after SIGKILL")
        }
        // Remaining cgroup members are the container's when its verified init
        // was just killed, or (as runc assumes) when it had no PID namespace.
        // A failed cleanup keeps the state so that delete can be retried.
        if let record {
            try Self.removeCgroup(record, killRemaining: action != .destroy || !record.pidNamespace)
        }
        try container.destroy()
    }

    /// runc's `list`: every container under the root, sorted by ID.
    ///
    /// - Returns: The containers' states, and one warning per entry that could
    ///   not be read (skipped, as in runc).
    /// - Throws: `RuntimeError` when a custom root does not exist; a missing
    ///   default root lists nothing.
    public func list() throws -> (reports: [ContainerStateReport], warnings: [String]) {
        guard let root = try StateRoot.open(root, create: false) else {
            if usesDefaultRoot { return ([], []) }
            throw RuntimeError("state root \(self.root) does not exist")
        }
        // Snapshots pin each generation independently; disappearance during
        // enumeration is ordinary concurrent deletion rather than a warning.
        var reports: [ContainerStateReport] = []
        var warnings: [String] = []
        let names: [String]
        do {
            names = try root.descriptor.directoryEntries().sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        } catch {
            throw RuntimeError.system("list state directory", error)
        }
        for name in names {
            guard let id = try? ContainerID(name) else { continue }
            do {
                reports.append(try snapshot(root, id))
            } catch LifecycleError.notFound(_) {
                continue
            } catch {
                warnings.append("container \(name): \(error)")
            }
        }
        return (reports, warnings)
    }
}

extension ContainerLifecycle {
    private func lock(_ id: ContainerID) throws -> LockedContainer {
        guard let root = try StateRoot.open(root, create: false) else { throw LifecycleError.notFound(id) }
        return try LockedContainer.acquire(in: root, id: id)
    }

    private func snapshot(_ root: StateRoot, _ id: ContainerID) throws -> ContainerStateReport {
        // Pin the generation under the root membership lock, after any
        // creator has locked its new directory and before a delete can race.
        let directory = try root.openContainer(id)
        let observation = try ContainerObservation.read(from: directory)
        return ContainerStateReport(record: observation.record, id: id, status: observation.status, owner: directory.ownerName())
    }

    /// Kills the recorded init if it is still that process, and reports
    /// whether it is gone. With a PID namespace, killing its init kills every
    /// process in it; without one, other workload processes may survive.
    private static func killInit(_ record: ContainerRecord?) throws -> Bool {
        guard let record, let process = record.initProcess else { return true }
        let gone = try ProcessHandle.withVerified(process, separatePIDNamespace: record.pidNamespace) { handle in
            _ = try handle.signal(Kernel.Signal.kill)
            // runc thaws a paused container after SIGKILL. Identity checks
            // keep this best-effort thaw away from a replacement cgroup.
            if let identity = record.cgroup { try? CgroupLeaf.setFrozen(identity, frozen: false) }
            return handle.waitForExit(timeout: .seconds(10))
        }
        return gone ?? true
    }

    /// Removes the recorded cgroup, if any; a replaced cgroup is reported
    /// as a warning and left alone.
    private static func removeCgroup(_ record: ContainerRecord, killRemaining: Bool) throws {
        guard let cgroup = record.cgroup else { return }
        if let warning = try CgroupLeaf.remove(cgroup, killRemaining: killRemaining) {
            RuntimeDiagnostics.writeError("swift-container-runtime: warning: container \(record.id): \(warning)")
        }
    }

    /// Prepares the container's cgroup and records it before any init
    /// exists, so every later failure or command can find and remove it.
    private static func prepareCgroup(
        _ plan: OCIRunPlan, id: ContainerID, record: inout ContainerRecord, container: LockedContainer
    ) throws -> CgroupLeaf {
        let leaf = try CgroupLeaf.prepare(plan.cgroup, id: id)
        record.cgroup = leaf.identity
        do {
            try container.writeRecord(record)
        } catch {
            _ = try? CgroupLeaf.remove(leaf.identity, killRemaining: false)
            record.cgroup = nil
            throw error
        }
        return leaf
    }

    /// runc's report for a failed start: an OOM kill in the container's
    /// cgroup since it was prepared is the most likely cause of whatever
    /// failed. Kills counted before (in an adopted cgroup) are not claimed.
    private static func explainingOOM(_ error: any Error, _ leaf: CgroupLeaf?) -> any Error {
        guard let leaf, leaf.oomKilledSincePrepare else { return error }
        return RuntimeError("container init was OOM-killed (memory limit too low?): \(error)")
    }

    /// Cleanup after a failed create or run. The init this command launched
    /// is killed first, so whatever remains in its cgroup is the container's.
    /// If the cgroup cannot be removed, the state is kept for `delete`.
    private static func abandon(_ record: ContainerRecord, _ container: LockedContainer) {
        _ = try? killInit(record)
        do {
            try removeCgroup(record, killRemaining: true)
        } catch {
            RuntimeDiagnostics.writeError(
                "swift-container-runtime: warning: container \(record.id) kept for delete: \(error)"
            )
            return
        }
        try? container.destroy()
    }

    /// Early check, before state, locks, or cgroups open descriptors that
    /// could fill a hole in the preserved range; `NamespaceLauncher.run` repeats it.
    private static func verifiedPreserved(_ count: Int) throws -> PreservedDescriptors {
        let preserved = try PreservedDescriptors(count: count)
        try preserved.verify()
        return preserved
    }

    /// runc's checkTerminal: a console socket goes with exactly a detached
    /// process that requests a terminal. A foreground terminal, which runc
    /// proxies through its own stdio, is not implemented.
    private static func consoleAddress(_ path: String?, terminal: Bool, detached: Bool) throws -> UnixSocketAddress? {
        let address = try path.map { try UnixSocketAddress($0, option: "--console-socket") }
        if terminal && !detached {
            throw RuntimeError("process.terminal in the foreground is not implemented; detach and pass --console-socket")
        }
        if terminal && address == nil {
            throw RuntimeError("process.terminal needs --console-socket when the runtime detaches")
        }
        if !terminal && address != nil {
            throw RuntimeError("--console-socket needs a detached process with process.terminal")
        }
        return address
    }

    /// `create`, and with `start` a detached `run`. Holding the lock for the
    /// whole command means no other command observes a half-made container;
    /// any failure kills the init and removes the state.
    private func createOnLinux(
        id: ContainerID, plan: OCIRunPlan, start: Bool, pidFile: String?, preserved: PreservedDescriptors,
        pidfdSocket: UnixSocketAddress?, noNewKeyring: Bool, consoleSocket: UnixSocketAddress?
    ) throws {
        // Reserve and pin the generation before recording or launching an init.
        guard let root = try StateRoot.open(root, create: true) else { throw LifecycleError.notFound(id) }
        let container = try LockedContainer.create(in: root, id: id)
        var record = ContainerRecord(id: id, plan: plan, noNewKeyring: noNewKeyring)
        var leaf: CgroupLeaf? = nil
        do {
            try container.writeRecord(record)
            let cgroup = try Self.prepareCgroup(plan, id: id, record: &record, container: container)
            leaf = cgroup
            // The child drops only its inherited ownership; the parent keeps
            // the state lock through readiness and an optional detached start.
            let gate = try StartGate(container)
            var hooks = LaunchHooks()
            hooks.detached = true
            hooks.preserved = preserved
            hooks.closeInChildren = { container.detachInForkedChild() }
            hooks.placeInit = { try cgroup.join($0) }
            hooks.initStarted = { record.initProcess = $0 }
            // Recorded before the commit: an init that outlives this command
            // is always findable by later commands.
            hooks.ready = { try container.writeRecord(record) }
            // Commit readiness before asking the waiting init to execute.
            // Dialled after the ID is reserved, just before the fork, so an
            // invalid or duplicate ID never consumes a connection. A relative
            // path resolves in the bundle, as runc resolves it after chdir.
            let pidfd = try pidfdSocket.map { try PidfdSocket(connectingTo: $0, relativeTo: plan.bundle.string) }
            defer { pidfd?.close() }
            // Dialled like the pidfd socket; a relative path resolves in the bundle.
            let terminal = try consoleSocket.map {
                try TerminalSetup(connectingTo: $0, relativeTo: plan.bundle.string, size: plan.consoleSize, bindsConsole: true)
            }
            defer { terminal?.close() }
            _ = try plan.runOnLinux(
                hooks: hooks, gate: gate, pidfdSocket: pidfd,
                keyring: SessionKeyringSetup(id: id, disabled: noNewKeyring, isExec: false), terminal: terminal)
            if start { try StartProtocol.start(container) }
            if let pidFile, let process = record.initProcess {
                try PIDFile.write(process.pid, to: pidFile)
            }
        } catch {
            // Failed creates leave neither a live init, a cgroup, nor a
            // reserved ID (unless the cgroup cannot be removed).
            let reported = Self.explainingOOM(error, leaf)
            Self.abandon(record, container)
            throw reported
        }
    }

    /// Foreground `run`: state exists while the workload runs, so `state`,
    /// `kill`, and `delete --force` work from other processes, and it is
    /// removed when the workload exits or setup fails, as runc does.
    private func runForegroundOnLinux(
        id: ContainerID, plan: OCIRunPlan, keep: Bool, pidFile: String?, preserved: PreservedDescriptors,
        pidfdSocket: UnixSocketAddress?, noNewKeyring: Bool
    ) throws -> Int32 {
        // Keep the directory locked throughout setup, then publish the init
        // and unlock only after execution has been confirmed.
        guard let root = try StateRoot.open(root, create: true) else { throw LifecycleError.notFound(id) }
        let container = try LockedContainer.create(in: root, id: id)
        var record = ContainerRecord(id: id, plan: plan, noNewKeyring: noNewKeyring)
        var leaf: CgroupLeaf? = nil
        let status: Int32
        do {
            try container.writeRecord(record)
            let cgroup = try Self.prepareCgroup(plan, id: id, record: &record, container: container)
            leaf = cgroup
            var hooks = LaunchHooks()
            hooks.preserved = preserved
            hooks.closeInChildren = { container.detachInForkedChild() }
            hooks.placeInit = { try cgroup.join($0) }
            hooks.initStarted = { record.initProcess = $0 }
            hooks.executed = {
                if let pidFile, let process = record.initProcess {
                    try PIDFile.write(process.pid, to: pidFile)
                }
                try container.writeRecord(record)
                container.unlock()
            }
            // As in createOnLinux: after the ID is reserved, before the fork.
            let pidfd = try pidfdSocket.map { try PidfdSocket(connectingTo: $0, relativeTo: plan.bundle.string) }
            defer { pidfd?.close() }
            status = try plan.runOnLinux(hooks: hooks, pidfdSocket: pidfd, keyring: SessionKeyringSetup(id: id, disabled: noNewKeyring, isExec: false))
        } catch {
            // Recover setup failures only if this generation still owns its ID.
            let reported = Self.explainingOOM(error, leaf)
            if (try? container.lock()) != nil { Self.abandon(record, container) }
            throw reported
        }
        // Retained state and its cgroup are cleaned by an explicit delete.
        if keep { return status }
        do {
            // A concurrent `delete --force` may already have removed it. The
            // init has exited, so what remains in its cgroup (descendants
            // without a PID namespace) is the container's; runc kills them too.
            try container.lock()
            try Self.removeCgroup(record, killRemaining: true)
            try container.destroy()
        } catch LifecycleError.notFound(_) {
        } catch {
            RuntimeDiagnostics.writeError("swift-container-runtime: warning: remove container \(id.rawValue) (its state is kept for delete): \(error)")
        }
        return status
    }
}
