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

private func stateError(_ action: String, _ code: Int32 = errno) -> RuntimeError {
    RuntimeError("\(action): \(Errno(rawValue: code))")
}

/// Device and inode numbers of an owned descriptor, or nil if fstat fails.
func fileIdentity(_ owner: borrowing OwnedFileDescriptor) -> (device: dev_t, inode: ino_t)? {
    try? owner.withDescriptor { descriptor -> (device: dev_t, inode: ino_t)? in
        var status = stat()
        guard unsafe fstat(descriptor.rawValue, &status) == 0 else { return nil }
        return (status.st_dev, status.st_ino)
    }
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
            throw stateError("open state root \(path)")
        }
        let root = StateRoot(path: path, descriptor: OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw)))
        var status = stat()
        let result = try root.descriptor.withDescriptor { unsafe fstat($0.rawValue, &status) }
        guard result == 0 else { throw stateError("inspect state root \(path)") }
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
                throw stateError("create state root \(current)")
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
        guard raw >= 0 else { throw stateError("open state root lock") }
        let owner = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
        return try owner.withDescriptor { lockDescriptor in
            // OS flock coordinates separate processes; this synchronous scope
            // never suspends and never waits for an existing container lock.
            try takeStateLock(lockDescriptor, description: "state root")
            defer { _ = flock(lockDescriptor.rawValue, LOCK_UN) }
            return try body()
        }
    }

    /// Pins an existing generation while membership is stable. The caller
    /// must release the root lock before waiting for this directory's lock.
    func openContainer(_ id: ContainerID) throws -> OwnedFileDescriptor {
        let raw = try withMembershipLock { try openContainerRaw(id) }
        return OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
    }

    /// Only called while holding the root membership lock.
    fileprivate func openContainerRaw(_ id: ContainerID) throws -> Int32 {
        let raw = try descriptor.withDescriptor {
            unsafe linux_open_at($0.rawValue, id.rawValue, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0)
        }
        guard raw >= 0 else {
            if errno == ENOENT || errno == ENOTDIR { throw LifecycleError.notFound(id) }
            throw stateError("open state of container \(id.rawValue)")
        }
        return raw
    }

    /// Whether `directory` is still the entry named `id`, so an operation
    /// never touches a directory that was deleted and recreated meanwhile.
    func contains(_ directory: borrowing OwnedFileDescriptor, as id: ContainerID) throws -> Bool {
        guard let own = fileIdentity(directory) else { throw stateError("inspect state of container \(id.rawValue)") }
        var status = stat()
        let result = try descriptor.withDescriptor {
            unsafe fstatat($0.rawValue, id.rawValue, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            if errno == ENOENT { return false }
            throw stateError("inspect state of container \(id.rawValue)")
        }
        return status.st_dev == own.device && status.st_ino == own.inode
    }
}

/// Separate-process synchronous coordination requires a kernel lock rather
/// than Swift actor isolation. Both lock scopes have bounded waits and no await.
private func takeStateLock(_ descriptor: FileDescriptor, description: String) throws {
    var attempts = 0
    while flock(descriptor.rawValue, LOCK_EX | LOCK_NB) != 0 {
        guard errno == EWOULDBLOCK || errno == EINTR else { throw stateError("lock \(description)") }
        attempts += 1
        guard attempts < LockedContainer.lockAttempts else {
            throw RuntimeError("\(description) is busy: timed out waiting for its lock")
        }
        _ = usleep(LockedContainer.lockRetryMicroseconds)
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
    let id: ContainerID
    private(set) var directory: OwnedFileDescriptor
    private var locked = false

    /// Lock waits are bounded so a stuck holder produces an error, not a hang.
    static let lockAttempts = 3000
    static let lockRetryMicroseconds: UInt32 = 10_000

    private init(root: StateRoot, id: ContainerID, directory: consuming OwnedFileDescriptor) {
        self.root = root
        self.id = id
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
                throw stateError("create state of container \(id.rawValue)")
            }

            // The fresh directory cannot have an existing holder. Pin and
            // lock it before snapshots or other commands can open the name.
            do {
                let raw = try root.openContainerRaw(id)
                let container = LockedContainer(
                    root: root, id: id,
                    directory: OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
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
        let container = LockedContainer(root: root, id: id, directory: try root.openContainer(id))
        try container.lock()
        return container
    }

    /// Takes the lock (again) and confirms the directory is still current.
    func lock() throws {
        guard !locked else { return }
        try directory.withDescriptor { descriptor in
            try takeStateLock(descriptor, description: "container \(id.rawValue)")
        }
        locked = true
        guard try root.contains(directory, as: id) else {
            unlock()
            throw LifecycleError.notFound(id)
        }
    }

    func unlock() {
        guard locked else { return }
        locked = false
        _ = try? directory.withDescriptor { flock($0.rawValue, LOCK_UN) }
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
        try loadRecord(directory, id: id)
    }

    /// Replaces `state.json` atomically: write and fsync a temporary file,
    /// rename it over the record, then fsync the directory.
    func writeRecord(_ record: ContainerRecord) throws {
        // Prepare the complete replacement before touching the on-disk record.
        let bytes = try record.encoded()
        try directory.withDescriptor { directoryDescriptor in
            let raw = unsafe linux_open_at(
                directoryDescriptor.rawValue, StateFile.pendingRecord, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600
            )
            guard raw >= 0 else { throw stateError("write state of container \(id.rawValue)") }
            var file = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
            // Persist the temporary file before publishing it by atomic rename.
            try file.withDescriptor { descriptor in
                _ = try descriptor.writeAll(bytes)
                guard fsync(descriptor.rawValue) == 0 else { throw stateError("sync state of container \(id.rawValue)") }
            }
            try file.close()
            guard unsafe renameat(
                directoryDescriptor.rawValue, StateFile.pendingRecord, directoryDescriptor.rawValue, StateFile.record
            ) == 0 else {
                throw stateError("replace state of container \(id.rawValue)")
            }
            // Persist the rename as well; success must not hide a directory
            // fsync error after the record has become visible.
            guard fsync(directoryDescriptor.rawValue) == 0 else {
                throw stateError("sync state directory of container \(id.rawValue)")
            }
        }
    }

    /// The live status; the caller holds the lock, so a record without an
    /// init belongs to an aborted create and is stopped.
    func status(of record: ContainerRecord?) throws -> ContainerStatus {
        try containerStatus(record: record, directory: directory, lockHeldByCaller: true)
    }

    /// Removes the state directory and its files, if it is still the entry
    /// for this ID. Callers must have stopped the init first.
    func destroy() throws {
        // The container lock is already held. Membership is acquired only
        // for removal, so new opens cannot cross a delete/recreate boundary.
        try root.withMembershipLock {
            guard try root.contains(directory, as: id) else { return }
            // Remove only files in our pinned generation before unlinking its name.
            for name in try directoryEntries(directory) {
                let result = try directory.withDescriptor { descriptor in
                    var result = unsafe unlinkat(descriptor.rawValue, name, 0)
                    if result != 0 && errno == EISDIR { result = unsafe unlinkat(descriptor.rawValue, name, AT_REMOVEDIR) }
                    return result
                }
                guard result == 0 || errno == ENOENT else { throw stateError("remove state file \(name) of container \(id.rawValue)") }
            }
            let result = try root.descriptor.withDescriptor { unsafe unlinkat($0.rawValue, id.rawValue, AT_REMOVEDIR) }
            guard result == 0 || errno == ENOENT else { throw stateError("remove state of container \(id.rawValue)") }
        }
    }
}

/// Reads and validates `state.json`; nil if it was never written.
func loadRecord(_ directory: borrowing OwnedFileDescriptor, id: ContainerID) throws -> ContainerRecord? {
    let raw = try directory.withDescriptor { unsafe linux_open_at($0.rawValue, StateFile.record, O_RDONLY | O_NOFOLLOW, 0) }
    guard raw >= 0 else {
        if errno == ENOENT { return nil }
        throw stateError("read state of container \(id.rawValue)")
    }
    let file = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
    return try ContainerRecord.decode(try file.readAll(limit: ContainerRecord.maximumBytes), expectedID: id)
}

/// Whether `name` exists in `directory`, without following symlinks.
func entryExists(_ directory: borrowing OwnedFileDescriptor, _ name: String) throws -> Bool {
    var status = stat()
    let result = try directory.withDescriptor { unsafe fstatat($0.rawValue, name, &status, AT_SYMLINK_NOFOLLOW) }
    guard result == 0 else {
        if errno == ENOENT { return false }
        throw stateError("inspect \(name)")
    }
    return true
}

/// Probes, through a separate open file description, whether another
/// process holds the container lock.
private func isLockedByAnother(_ directory: borrowing OwnedFileDescriptor) throws -> Bool {
    let raw = try directory.withDescriptor { unsafe linux_open_at($0.rawValue, ".", O_RDONLY | O_DIRECTORY, 0) }
    guard raw >= 0 else { throw stateError("probe container lock") }
    let probe = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
    let result = try probe.withDescriptor { flock($0.rawValue, LOCK_SH | LOCK_NB) }
    if result == 0 {
        _ = try probe.withDescriptor { flock($0.rawValue, LOCK_UN) }
        return false
    }
    guard errno == EWOULDBLOCK else { throw stateError("probe container lock") }
    return true
}

/// Derives the status from the record, the verified init, and the start
/// socket. See `deriveStatus` for the rules.
func containerStatus(
    record: ContainerRecord?, directory: borrowing OwnedFileDescriptor, lockHeldByCaller: Bool
) throws -> ContainerStatus {
    guard let record, let process = record.initProcess else {
        let creating = try !lockHeldByCaller && isLockedByAnother(directory)
        return deriveStatus(hasInit: false, initAlive: false, creatorActive: creating, startSocketPresent: false)
    }
    let alive = try withVerifiedProcess(process, separatePIDNamespace: record.pidNamespace) { _ in true } ?? false
    let waiting = try alive && entryExists(directory, StateFile.startSocket)
    // A dead init is stopped even if an empty cgroup is still frozen.
    // Only the recorded cgroup generation may contribute a paused state.
    let frozen = try alive && record.cgroup.map { try CgroupLeaf.isFrozen($0) } == true
    return deriveStatus(hasInit: true, initAlive: alive, creatorActive: false, startSocketPresent: waiting, frozen: frozen)
}

/// Names in a directory other than `.` and `..`.
func directoryEntries(_ directory: borrowing OwnedFileDescriptor) throws -> [String] {
    let raw = try directory.withDescriptor { unsafe linux_open_at($0.rawValue, ".", O_RDONLY | O_DIRECTORY, 0) }
    guard raw >= 0 else { throw stateError("list state directory") }
    // fdopendir takes ownership of the new descriptor; closedir closes it.
    guard let stream = unsafe fdopendir(raw) else {
        let code = errno
        _ = close(raw)
        throw stateError("list state directory", code)
    }
    defer { _ = unsafe closedir(stream) }
    var names: [String] = []
    while true {
        // readdir signals an error only through errno, and the String work
        // below may change errno, so clear it before every call.
        errno = 0
        guard let entry = unsafe readdir(stream) else {
            guard errno == 0 else { throw stateError("list state directory") }
            return names
        }
        let name = unsafe withUnsafeBytes(of: entry.pointee.d_name) { bytes in
            unsafe String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        if name != "." && name != ".." { names.append(name) }
    }
}

/// The state directory owner's user name, or `#uid` as in runc.
func ownerName(_ directory: borrowing OwnedFileDescriptor) -> String {
    var status = stat()
    guard (try? directory.withDescriptor({ unsafe fstat($0.rawValue, &status) })) == 0 else { return "" }
    guard let entry = unsafe getpwuid(status.st_uid), let name = unsafe entry.pointee.pw_name else {
        return "#\(status.st_uid)"
    }
    return unsafe String(cString: name)
}

/// The current UTC time in RFC 3339 form.
func currentTimestamp() -> String {
    var now = timespec()
    _ = unsafe clock_gettime(CLOCK_REALTIME, &now)
    return formatRFC3339(seconds: Int64(now.tv_sec), nanoseconds: Int64(now.tv_nsec))
}
#endif
