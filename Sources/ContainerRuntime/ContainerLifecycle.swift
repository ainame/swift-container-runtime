#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
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
    /// Like runc's `/run/runc`.
    public static let defaultRoot = "/run/swift-container-runtime"

    public let root: FilePath

    public init(root: String = ContainerLifecycle.defaultRoot) throws {
        guard !root.isEmpty, !root.utf8.contains(0) else {
            throw RuntimeError("--root must be non-empty and contain no NUL")
        }
        self.root = FilePath(root)
    }

    private var usesDefaultRoot: Bool { root == FilePath(Self.defaultRoot) }

    /// Prepares the container and leaves its init waiting for `start`. The
    /// workload inherits this process's stdin, stdout, and stderr, as in runc.
    @available(*, noasync, message: "create containers before starting async work")
    public func create(id: ContainerID, plan: OCIRunPlan) throws {
        #if os(Linux)
        try createOnLinux(id: id, plan: plan, start: false)
        #else
        throw Self.unsupported
        #endif
    }

    /// Runs a container. In the foreground this waits for the workload and
    /// removes its state afterwards, returning the workload status. Detached,
    /// it returns 0 after a confirmed start and keeps the state.
    @available(*, noasync, message: "launch containers before starting async work")
    public func run(id: ContainerID, plan: OCIRunPlan, detach: Bool) throws -> Int32 {
        #if os(Linux)
        if detach {
            try createOnLinux(id: id, plan: plan, start: true)
            return 0
        }
        return try runForegroundOnLinux(id: id, plan: plan)
        #else
        throw Self.unsupported
        #endif
    }

    /// Executes the workload of a created container exactly once.
    public func start(id: ContainerID) throws {
        #if os(Linux)
        let container = try lock(id)
        let record = try container.readRecord()
        _ = try LifecycleOperation.start.action(for: try container.status(of: record), id: id)
        try requestStart(container)
        #else
        throw Self.unsupported
        #endif
    }

    public func state(id: ContainerID) throws -> ContainerStateReport {
        #if os(Linux)
        guard let root = try StateRoot.open(root, create: false) else { throw LifecycleError.notFound(id) }
        return try snapshot(root, id)
        #else
        throw Self.unsupported
        #endif
    }

    /// Signals the verified init of a created or running container.
    public func kill(id: ContainerID, signal: Int32) throws {
        #if os(Linux)
        let container = try lock(id)
        let record = try container.readRecord()
        _ = try LifecycleOperation.kill.action(for: try container.status(of: record), id: id)
        guard let record, let process = record.initProcess,
              try withVerifiedProcess(process, separatePIDNamespace: record.pidNamespace, { try $0.signal(signal) }) == true else {
            throw LifecycleError.invalidTransition(id: id, operation: "kill", status: .stopped)
        }
        #else
        throw Self.unsupported
        #endif
    }

    /// Removes a stopped container. A created container's waiting init is
    /// killed first, as in runc; a running one requires `force`, which sends
    /// SIGKILL and waits up to 10 seconds for the init to exit. Forcing the
    /// deletion of a missing container succeeds, as in runc.
    public func delete(id: ContainerID, force: Bool) throws {
        #if os(Linux)
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
        #else
        throw Self.unsupported
        #endif
    }

    /// Every container under the root, sorted by ID. Entries that cannot be
    /// read are reported as warnings and skipped, as in runc. A missing
    /// default root lists nothing; a missing custom root is an error.
    public func list() throws -> (reports: [ContainerStateReport], warnings: [String]) {
        #if os(Linux)
        guard let root = try StateRoot.open(root, create: false) else {
            if usesDefaultRoot { return ([], []) }
            throw RuntimeError("state root \(self.root) does not exist")
        }
        // Snapshots pin each generation independently; disappearance during
        // enumeration is ordinary concurrent deletion rather than a warning.
        var reports: [ContainerStateReport] = []
        var warnings: [String] = []
        let names = try directoryEntries(root.descriptor).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
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
        #else
        throw Self.unsupported
        #endif
    }

    private static var unsupported: RuntimeError {
        RuntimeError("container lifecycle commands require Linux")
    }
}

#if os(Linux)
extension ContainerLifecycle {
    private func lock(_ id: ContainerID) throws -> LockedContainer {
        guard let root = try StateRoot.open(root, create: false) else { throw LifecycleError.notFound(id) }
        return try LockedContainer.acquire(in: root, id: id)
    }

    private func snapshot(_ root: StateRoot, _ id: ContainerID) throws -> ContainerStateReport {
        // Pin the generation under the root membership lock, after any
        // creator has locked its new directory and before a delete can race.
        let directory = try root.openContainer(id)
        let record = try loadRecord(directory, id: id)
        let status = try containerStatus(record: record, directory: directory, lockHeldByCaller: false)
        return ContainerStateReport(record: record, id: id, status: status, owner: ownerName(directory))
    }

    /// Kills the recorded init if it is still that process, and reports
    /// whether it is gone. With a PID namespace, killing its init kills every
    /// process in it; without one, other workload processes may survive.
    private static func killInit(_ record: ContainerRecord?) throws -> Bool {
        guard let record, let process = record.initProcess else { return true }
        let gone = try withVerifiedProcess(process, separatePIDNamespace: record.pidNamespace) { handle in
            _ = try handle.signal(SIGKILL)
            return handle.waitForExit(milliseconds: 10_000)
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

    /// `create`, and with `start` a detached `run`. Holding the lock for the
    /// whole command means no other command observes a half-made container;
    /// any failure kills the init and removes the state.
    private func createOnLinux(id: ContainerID, plan: OCIRunPlan, start: Bool) throws {
        // Reserve and pin the generation before recording or launching an init.
        guard let root = try StateRoot.open(root, create: true) else { throw LifecycleError.notFound(id) }
        let container = try LockedContainer.create(in: root, id: id)
        var record = ContainerRecord(id: id, plan: plan, created: currentTimestamp())
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
            hooks.closeInChildren = { container.detachInForkedChild() }
            hooks.placeInit = { try cgroup.join($0) }
            hooks.initStarted = { record.initProcess = $0 }
            // Recorded before the commit: an init that outlives this command
            // is always findable by later commands.
            hooks.ready = { try container.writeRecord(record) }
            // Commit readiness before asking the waiting init to execute.
            _ = try plan.runOnLinux(hooks: hooks, gate: gate)
            if start { try requestStart(container) }
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
    private func runForegroundOnLinux(id: ContainerID, plan: OCIRunPlan) throws -> Int32 {
        // Keep the directory locked throughout setup, then publish the init
        // and unlock only after execution has been confirmed.
        guard let root = try StateRoot.open(root, create: true) else { throw LifecycleError.notFound(id) }
        let container = try LockedContainer.create(in: root, id: id)
        var record = ContainerRecord(id: id, plan: plan, created: currentTimestamp())
        var leaf: CgroupLeaf? = nil
        let status: Int32
        do {
            try container.writeRecord(record)
            let cgroup = try Self.prepareCgroup(plan, id: id, record: &record, container: container)
            leaf = cgroup
            var hooks = LaunchHooks()
            hooks.closeInChildren = { container.detachInForkedChild() }
            hooks.placeInit = { try cgroup.join($0) }
            hooks.initStarted = { record.initProcess = $0 }
            hooks.executed = {
                try container.writeRecord(record)
                container.unlock()
            }
            status = try plan.runOnLinux(hooks: hooks)
        } catch {
            // Recover setup failures only if this generation still owns its ID.
            let reported = Self.explainingOOM(error, leaf)
            if (try? container.lock()) != nil { Self.abandon(record, container) }
            throw reported
        }
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
#endif
