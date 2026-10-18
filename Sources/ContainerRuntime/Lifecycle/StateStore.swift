#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import LinuxAPI
import SystemPackage

/// The file names inside a container's state directory.
enum StateFile {
    static let record = "state.json"
    static let pendingRecord = "state.json.new"
    /// The created init's listening socket. Its presence distinguishes
    /// created from running; `start` removes it once the init has accepted
    /// the request, as the commit point (see `StartGate`).
    static let startSocket = "start.sock"
}

/// The directory holding one subdirectory per container, like runc's
/// `--root`. Paths below it are resolved with `*at` calls relative to this
/// descriptor and never follow symlinks; the root path's ancestors are
/// trusted. The root must belong to the caller and must not be writable by
/// group or others.
final class StateRoot {
    let path: FilePath
    let descriptor: OwnedFileDescriptor

    /// Opens the root, creating missing components with mode 0700 when
    /// `create` is set (as runc's MkdirAll does). Returns nil when the root
    /// does not exist and `create` is not set.
    static func open(_ path: FilePath, create: Bool) throws -> StateRoot? {
        if create { try makeDirectories(path.string) }
        let raw = unsafe linux_open_at(AT_FDCWD, path.string, O_RDONLY | O_DIRECTORY | O_NOFOLLOW, 0)
        guard raw >= 0 else {
            if errno == ENOENT && !create { return nil }
            throw RuntimeError.system("open state root \(path)")
        }
        let root = StateRoot(path: path, descriptor: OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw)))
        var status = stat()
        let result = try root.descriptor.withDescriptor { unsafe fstat($0.rawValue, &status) }
        guard result == 0 else { throw RuntimeError.system("inspect state root \(path)") }
        guard status.st_uid == geteuid(), status.st_mode & 0o022 == 0 else {
            throw RuntimeError("state root \(path) must be owned by uid \(geteuid()) and not writable by group or others")
        }
        return root
    }

    private init(path: FilePath, descriptor: consuming OwnedFileDescriptor) {
        self.path = path
        self.descriptor = descriptor
    }

    private static func makeDirectories(_ path: String) throws {
        var current = path.hasPrefix("/") ? "" : "."
        for component in path.split(separator: "/") {
            current += "/" + component
            guard unsafe mkdir(current, 0o700) == 0 || errno == EEXIST else {
                throw RuntimeError.system("create state root \(current)")
            }
        }
    }

    /// Serializes directory membership across independent runtime processes.
    /// Each scope opens its own file description: reusing the root descriptor
    /// would make flock reentrant across callers that share this StateRoot.
    func withMembershipLock<Result>(_ body: () throws -> Result) throws -> Result {
        let raw = try descriptor.withDescriptor {
            unsafe linux_open_at($0.rawValue, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0)
        }
        guard raw >= 0 else { throw RuntimeError.system("open state root lock") }
        let owner = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
        return try owner.withDescriptor { lockDescriptor in
            // OS flock coordinates separate processes; this synchronous scope
            // never suspends and never waits for an existing container lock.
            try StateLock.acquire(lockDescriptor, description: "state root")
            defer { _ = flock(lockDescriptor.rawValue, LOCK_UN) }
            return try body()
        }
    }

    /// Pins an existing generation while membership is stable. The caller
    /// must release the root lock before waiting for this directory's lock.
    func openContainer(_ id: ContainerID) throws -> ContainerDirectory {
        let raw = try withMembershipLock { try openContainerRaw(id) }
        return ContainerDirectory(id: id, descriptor: OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw)))
    }

    /// Only called while holding the root membership lock.
    fileprivate func openContainerRaw(_ id: ContainerID) throws -> Int32 {
        let raw = try descriptor.withDescriptor {
            unsafe linux_open_at($0.rawValue, id.rawValue, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0)
        }
        guard raw >= 0 else {
            if errno == ENOENT || errno == ENOTDIR { throw LifecycleError.notFound(id) }
            throw RuntimeError.system("open state of container \(id.rawValue)")
        }
        return raw
    }

    /// Whether `directory` is still the entry named `id`, so an operation
    /// never touches a directory that was deleted and recreated meanwhile.
    func contains(_ directory: borrowing ContainerDirectory) throws -> Bool {
        let id = directory.id
        guard let own = directory.descriptor.identity() else { throw RuntimeError.system("inspect state of container \(id.rawValue)") }
        var status = stat()
        let result = try descriptor.withDescriptor {
            unsafe fstatat($0.rawValue, id.rawValue, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            if errno == ENOENT { return false }
            throw RuntimeError.system("inspect state of container \(id.rawValue)")
        }
        return status.st_dev == own.device && status.st_ino == own.inode
    }
}

/// A container state directory held under an exclusive `flock`.
///
/// Every mutating command (create, start, kill, delete, run) takes this
/// lock for one short, synchronous critical section; `state` and `list` read
/// without it because the record is replaced atomically. The lock is on the
/// directory's own open file description, so the kernel releases it if the
/// holder dies. Forked children close their inherited copy first
/// (`detachInForkedChild`) without unlocking the parent's shared flock.
final class LockedContainer {
    let root: StateRoot
    var id: ContainerID { directory.id }
    private(set) var directory: ContainerDirectory
    private var locked = false

    private init(root: StateRoot, directory: consuming ContainerDirectory) {
        self.root = root
        self.directory = directory
    }

    /// Creates, pins and locks a new directory under the membership lock.
    /// Deletion cannot replace the generation between mkdir and open.
    static func create(in root: StateRoot, id: ContainerID) throws -> LockedContainer {
        try root.withMembershipLock {
            // Reserve the name atomically while no delete can remove it.
            let result = try root.descriptor.withDescriptor { unsafe mkdirat($0.rawValue, id.rawValue, 0o700) }
            guard result == 0 else {
                if errno == EEXIST { throw LifecycleError.alreadyExists(id) }
                throw RuntimeError.system("create state of container \(id.rawValue)")
            }

            // The fresh directory cannot have an existing holder. Pin and
            // lock it before snapshots or other commands can open the name.
            do {
                let raw = try root.openContainerRaw(id)
                let container = LockedContainer(
                    root: root,
                    directory: ContainerDirectory(id: id, descriptor: OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw)))
                )
                try container.lock()
                return container
            } catch {
                _ = try? root.descriptor.withDescriptor { unsafe unlinkat($0.rawValue, id.rawValue, AT_REMOVEDIR) }
                throw error
            }
        }
    }

    /// Opens and locks an existing state directory.
    static func acquire(in root: StateRoot, id: ContainerID) throws -> LockedContainer {
        let container = LockedContainer(root: root, directory: try root.openContainer(id))
        try container.lock()
        return container
    }

    /// Takes the lock (again) and confirms the directory is still current.
    func lock() throws {
        guard !locked else { return }
        try directory.descriptor.withDescriptor { descriptor in
            try StateLock.acquire(descriptor, description: "container \(id.rawValue)")
        }
        locked = true
        guard try root.contains(directory) else {
            unlock()
            throw LifecycleError.notFound(id)
        }
    }

    func unlock() {
        guard locked else { return }
        locked = false
        _ = try? directory.descriptor.withDescriptor { flock($0.rawValue, LOCK_UN) }
    }

    /// A fork shares the parent's flock open-file description. Invalidate
    /// child ownership before closing, and never issue LOCK_UN from a child.
    func detachInForkedChild() {
        locked = false
        try? directory.close()
    }

    deinit {
        unlock()
    }

    func readRecord() throws -> ContainerRecord? {
        try directory.readRecord()
    }

    /// Replaces `state.json` atomically: write and fsync a temporary file,
    /// rename it over the record, then fsync the directory.
    func writeRecord(_ record: ContainerRecord) throws {
        // Prepare the complete replacement before touching the on-disk record.
        let bytes = try record.encoded()
        try directory.descriptor.withDescriptor { directoryDescriptor in
            let raw = unsafe linux_open_at(
                directoryDescriptor.rawValue, StateFile.pendingRecord, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600
            )
            guard raw >= 0 else { throw RuntimeError.system("write state of container \(id.rawValue)") }
            var file = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
            // Persist the temporary file before publishing it by atomic rename.
            try file.withDescriptor { descriptor in
                _ = try descriptor.writeAll(bytes)
                guard fsync(descriptor.rawValue) == 0 else { throw RuntimeError.system("sync state of container \(id.rawValue)") }
            }
            try file.close()
            guard unsafe renameat(
                directoryDescriptor.rawValue, StateFile.pendingRecord, directoryDescriptor.rawValue, StateFile.record
            ) == 0 else {
                throw RuntimeError.system("replace state of container \(id.rawValue)")
            }
            // Persist the rename as well; success must not hide a directory
            // fsync error after the record has become visible.
            guard fsync(directoryDescriptor.rawValue) == 0 else {
                throw RuntimeError.system("sync state directory of container \(id.rawValue)")
            }
        }
    }

    /// The live status; the caller holds the lock, so a record without an
    /// init belongs to an aborted create and is stopped.
    func status(of record: ContainerRecord?) throws -> ContainerStatus {
        try ContainerObservation.status(of: record, in: directory)
    }

    /// Removes the state directory and its files, if it is still the entry
    /// for this ID. Callers must have stopped the init first.
    func destroy() throws {
        // The container lock is already held. Membership is acquired only
        // for removal, so new opens cannot cross a delete/recreate boundary.
        try root.withMembershipLock {
            guard try root.contains(directory) else { return }
            // Remove only files in our pinned generation before unlinking its name.
            for name in try directory.descriptor.directoryEntries() {
                let result = try directory.descriptor.withDescriptor { descriptor in
                    var result = unsafe unlinkat(descriptor.rawValue, name, 0)
                    if result != 0 && errno == EISDIR { result = unsafe unlinkat(descriptor.rawValue, name, AT_REMOVEDIR) }
                    return result
                }
                guard result == 0 || errno == ENOENT else { throw RuntimeError.system("remove state file \(name) of container \(id.rawValue)") }
            }
            let result = try root.descriptor.withDescriptor { unsafe unlinkat($0.rawValue, id.rawValue, AT_REMOVEDIR) }
            guard result == 0 || errno == ENOENT else { throw RuntimeError.system("remove state of container \(id.rawValue)") }
        }
    }
}


/// A pinned state-directory generation; opening or creating it requires the root membership lock.
struct ContainerDirectory: ~Copyable {
    let id: ContainerID
    private(set) var descriptor: OwnedFileDescriptor

    fileprivate init(id: ContainerID, descriptor: consuming OwnedFileDescriptor) {
        self.id = id
        self.descriptor = descriptor
    }

    /// Drops inherited ownership without unlocking the parent's shared flock.
    mutating func close() throws {
        try descriptor.close()
    }

    /// Reads and validates `state.json`; nil if it was never written.
    func readRecord() throws -> ContainerRecord? {
        let raw = try descriptor.withDescriptor { unsafe linux_open_at($0.rawValue, StateFile.record, O_RDONLY | O_NOFOLLOW, 0) }
        guard raw >= 0 else {
            if errno == ENOENT { return nil }
            throw RuntimeError.system("read state of container \(id.rawValue)")
        }
        let file = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
        return try ContainerRecord.decode(try file.readAll(limit: ContainerRecord.maximumBytes), expectedID: id)
    }

    /// Whether `name` exists in `directory`, without following symlinks.
    func contains(_ name: String) throws -> Bool {
        var status = stat()
        let result = try descriptor.withDescriptor { unsafe fstatat($0.rawValue, name, &status, AT_SYMLINK_NOFOLLOW) }
        guard result == 0 else {
            if errno == ENOENT { return false }
            throw RuntimeError.system("inspect \(name)")
        }
        return true
    }

    /// Probes a separate open file description for a holder of this generation's lock.
    func isLocked() throws -> Bool {
        let raw = try descriptor.withDescriptor { unsafe linux_open_at($0.rawValue, ".", O_RDONLY | O_DIRECTORY, 0) }
        guard raw >= 0 else { throw RuntimeError.system("probe container lock") }
        let probe = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
        let result = try probe.withDescriptor { flock($0.rawValue, LOCK_SH | LOCK_NB) }
        if result == 0 {
            _ = try probe.withDescriptor { flock($0.rawValue, LOCK_UN) }
            return false
        }
        guard errno == EWOULDBLOCK else { throw RuntimeError.system("probe container lock") }
        return true
    }

    /// The state directory owner's user name, or `#uid` as in runc.
    func ownerName() -> String {
        var status = stat()
        guard (try? descriptor.withDescriptor({ unsafe fstat($0.rawValue, &status) })) == 0 else { return "" }
        guard let entry = unsafe getpwuid(status.st_uid), let name = unsafe entry.pointee.pw_name else {
            return "#\(status.st_uid)"
        }
        return unsafe String(cString: name)
    }
}

/// Bounded synchronous coordination between independent runtime processes.
private enum StateLock {
    static let attemptsLimit = 3000
    static let retryMicroseconds: UInt32 = 10_000

    /// Separate-process synchronous coordination requires a kernel lock rather
    /// than Swift actor isolation. Both lock scopes have bounded waits and no await.
    static func acquire(_ descriptor: FileDescriptor, description: String) throws {
        var attempts = 0
        while flock(descriptor.rawValue, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw RuntimeError.system("lock \(description)") }
            attempts += 1
            guard attempts < attemptsLimit else {
                throw RuntimeError("\(description) is busy: timed out waiting for its lock")
            }
            _ = usleep(retryMicroseconds)
        }
    }
}
#endif
