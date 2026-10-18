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
        let descriptor: OwnedFileDescriptor
        do {
            descriptor = try Kernel.File.open(path.string, .readOnly, options: [.directory, .noFollow])
        } catch .noSuchFileOrDirectory where !create {
            return nil
        } catch {
            throw RuntimeError.system("open state root \(path)", error)
        }
        let root = StateRoot(path: path, descriptor: descriptor)
        let status: FileStatus
        do {
            status = try root.descriptor.withDescriptor { try Kernel.File.status(of: $0) }
        } catch {
            throw RuntimeError.system("inspect state root \(path)", error)
        }
        let user = Kernel.Process.effectiveUserID
        guard status.owner == user, status.mode & 0o022 == 0 else {
            throw RuntimeError("state root \(path) must be owned by uid \(user) and not writable by group or others")
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
            do {
                try Kernel.File.makeDirectory(current, permissions: .ownerReadWriteExecute)
            } catch .fileExists {
                continue
            } catch {
                throw RuntimeError.system("create state root \(current)", error)
            }
        }
    }

    /// Serializes directory membership across independent runtime processes.
    /// Each scope opens its own file description: reusing the root descriptor
    /// would make flock reentrant across callers that share this StateRoot.
    func withMembershipLock<Result>(_ body: () throws -> Result) throws -> Result {
        let owner: OwnedFileDescriptor
        do {
            owner = try Kernel.File.open(".", in: descriptor, .readOnly, options: .directory)
        } catch {
            throw RuntimeError.system("open state root lock", error)
        }
        return try owner.withDescriptor { lockDescriptor in
            // OS flock coordinates separate processes; this synchronous scope
            // never suspends and never waits for an existing container lock.
            try StateLock.acquire(lockDescriptor, description: "state root")
            defer { Kernel.File.unlock(lockDescriptor) }
            return try body()
        }
    }

    /// Pins an existing generation while membership is stable. The caller
    /// must release the root lock before waiting for this directory's lock.
    func openContainer(_ id: ContainerID) throws -> ContainerDirectory {
        var descriptor = OwnedFileDescriptor()
        try withMembershipLock { descriptor = try openContainerDescriptor(id) }
        return ContainerDirectory(id: id, descriptor: descriptor)
    }

    /// Only called while holding the root membership lock.
    fileprivate func openContainerDescriptor(_ id: ContainerID) throws -> OwnedFileDescriptor {
        do {
            return try Kernel.File.open(id.rawValue, in: descriptor, .readOnly, options: [.directory, .noFollow])
        } catch Errno.noSuchFileOrDirectory, Errno.notDirectory {
            throw LifecycleError.notFound(id)
        } catch {
            throw RuntimeError.system("open state of container \(id.rawValue)", error)
        }
    }

    /// Whether `directory` is still the entry named `id`, so an operation
    /// never touches a directory that was deleted and recreated meanwhile.
    func contains(_ directory: borrowing ContainerDirectory) throws -> Bool {
        let id = directory.id
        guard let own = directory.descriptor.identity() else { throw RuntimeError.system("inspect state of container \(id.rawValue)") }
        do {
            let status = try descriptor.withDescriptor { root in try Kernel.File.status(of: id.rawValue, in: root) }
            return status.identity == own
        } catch Errno.noSuchFileOrDirectory {
            return false
        } catch {
            throw RuntimeError.system("inspect state of container \(id.rawValue)", error)
        }
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
            do {
                try root.descriptor.withDescriptor {
                    try Kernel.File.makeDirectory(id.rawValue, in: $0, permissions: .ownerReadWriteExecute)
                }
            } catch Errno.fileExists {
                throw LifecycleError.alreadyExists(id)
            } catch {
                throw RuntimeError.system("create state of container \(id.rawValue)", error)
            }

            // The fresh directory cannot have an existing holder. Pin and
            // lock it before snapshots or other commands can open the name.
            do {
                let container = LockedContainer(
                    root: root, directory: ContainerDirectory(id: id, descriptor: try root.openContainerDescriptor(id))
                )
                try container.lock()
                return container
            } catch {
                try? root.descriptor.withDescriptor { try Kernel.File.remove(id.rawValue, in: $0, isDirectory: true) }
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
        try? directory.descriptor.withDescriptor { Kernel.File.unlock($0) }
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
        let id = id.rawValue
        try directory.descriptor.withDescriptor { directoryDescriptor in
            var file: OwnedFileDescriptor
            do {
                file = try Kernel.File.open(
                    StateFile.pendingRecord, in: directoryDescriptor, .writeOnly,
                    options: [.create, .truncate, .noFollow], permissions: [.ownerReadWrite])
            } catch {
                throw RuntimeError.system("write state of container \(id)", error)
            }
            // Persist the temporary file before publishing it by atomic rename.
            try file.withDescriptor { descriptor in
                _ = try descriptor.writeAll(bytes)
                do { try Kernel.File.synchronize(descriptor) } catch { throw RuntimeError.system("sync state of container \(id)", error) }
            }
            try file.close()
            do {
                try Kernel.File.rename(StateFile.pendingRecord, to: StateFile.record, in: directoryDescriptor)
            } catch {
                throw RuntimeError.system("replace state of container \(id)", error)
            }
            // Persist the rename as well; success must not hide a directory
            // fsync error after the record has become visible.
            do {
                try Kernel.File.synchronize(directoryDescriptor)
            } catch {
                throw RuntimeError.system("sync state directory of container \(id)", error)
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
            let names: [String]
            do { names = try directory.descriptor.directoryEntries() } catch { throw RuntimeError.system("list state directory", error) }
            for name in names {
                do {
                    try directory.descriptor.withDescriptor { descriptor in
                        do {
                            try Kernel.File.remove(name, in: descriptor)
                        } catch .isDirectory {
                            try Kernel.File.remove(name, in: descriptor, isDirectory: true)
                        }
                    }
                } catch Errno.noSuchFileOrDirectory {
                    continue
                } catch {
                    throw RuntimeError.system("remove state file \(name) of container \(id.rawValue)", error)
                }
            }
            do {
                try root.descriptor.withDescriptor { try Kernel.File.remove(id.rawValue, in: $0, isDirectory: true) }
            } catch Errno.noSuchFileOrDirectory {
                return
            } catch {
                throw RuntimeError.system("remove state of container \(id.rawValue)", error)
            }
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
        let file: OwnedFileDescriptor
        do {
            file = try Kernel.File.open(StateFile.record, in: descriptor, .readOnly, options: .noFollow)
        } catch Errno.noSuchFileOrDirectory {
            return nil
        } catch {
            throw RuntimeError.system("read state of container \(id.rawValue)", error)
        }
        return try ContainerRecord.decode(try file.readAll(limit: ContainerRecord.maximumBytes), expectedID: id)
    }

    /// Whether `name` exists in `directory`, without following symlinks.
    func contains(_ name: String) throws -> Bool {
        do {
            _ = try descriptor.withDescriptor { try Kernel.File.status(of: name, in: $0) }
            return true
        } catch Errno.noSuchFileOrDirectory {
            return false
        } catch {
            throw RuntimeError.system("inspect \(name)", error)
        }
    }

    /// Probes a separate open file description for a holder of this generation's lock.
    func isLocked() throws -> Bool {
        do {
            let probe = try Kernel.File.open(".", in: descriptor, .readOnly, options: .directory)
            try probe.withDescriptor { probe in
                try Kernel.File.lock(probe, .shared)
                Kernel.File.unlock(probe)
            }
            return false
        } catch Errno.wouldBlock {
            return true
        } catch {
            throw RuntimeError.system("probe container lock", error)
        }
    }

    /// The state directory owner's user name, or `#uid` as in runc.
    func ownerName() -> String {
        guard let status = try? descriptor.withDescriptor({ try Kernel.File.status(of: $0) }) else { return "" }
        return Kernel.Process.userName(of: status.owner) ?? "#\(status.owner)"
    }
}

/// Bounded synchronous coordination between independent runtime processes.
private enum StateLock {
    static let attemptsLimit = 3000
    static let retryDelay = Duration.milliseconds(10)

    /// Separate-process synchronous coordination requires a kernel lock rather
    /// than Swift actor isolation. Both lock scopes have bounded waits and no await.
    static func acquire(_ descriptor: FileDescriptor, description: String) throws {
        var attempts = 0
        while true {
            do {
                try Kernel.File.lock(descriptor, .exclusive)
                return
            } catch .wouldBlock, .interrupted {
                attempts += 1
                guard attempts < attemptsLimit else {
                    throw RuntimeError("\(description) is busy: timed out waiting for its lock")
                }
                Kernel.Process.sleep(for: retryDelay)
            } catch {
                throw RuntimeError.system("lock \(description)", error)
            }
        }
    }
}
