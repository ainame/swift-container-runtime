#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import LinuxAPI
import SystemPackage

/// A live observation of one pinned generation, separate from storage and lock ownership.
struct ContainerObservation {
    let record: ContainerRecord?
    let status: ContainerStatus

    /// Unlocked readers probe a separate lock description to recognize an active creator.
    static func read(from directory: borrowing ContainerDirectory) throws -> ContainerObservation {
        let record = try directory.readRecord()
        let status: ContainerStatus
        if record?.initProcess == nil, try directory.isLocked() {
            status = .creating
        } else {
            status = try Self.status(of: record, in: directory)
        }
        return ContainerObservation(record: record, status: status)
    }

    /// Derives the status from the record, the verified init, and the start
    /// socket. The caller holds the directory lock, so a missing init is stopped.
    /// See `ContainerStatus.derive` for the rules.
    static func status(of record: ContainerRecord?, in directory: borrowing ContainerDirectory) throws -> ContainerStatus {
        guard let record, let process = record.initProcess else {
            return .stopped
        }
        let alive = try ProcessHandle.withVerified(process, separatePIDNamespace: record.pidNamespace) { _ in true } ?? false
        let waiting = try alive && directory.contains(StateFile.startSocket)
        // A dead init is stopped even if an empty cgroup is still frozen.
        // Only the recorded cgroup generation may contribute a paused state.
        let frozen = try alive && record.cgroup.map { try CgroupLeaf.isFrozen($0) } == true
        return ContainerStatus.derive(hasInit: true, initAlive: alive, creatorActive: false, startSocketPresent: waiting, frozen: frozen)
    }
}
#endif
