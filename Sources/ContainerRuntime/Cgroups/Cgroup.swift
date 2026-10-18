import SystemPackage

/// One directory of the cgroup v2 hierarchy, opened beneath the mount root
/// one component at a time without following symlinks, so a path can never
/// leave the hierarchy. Interface files are opened relative to it.
private final class CgroupDirectory {
    static let mountPoint = "/sys/fs/cgroup"

    let descriptor: OwnedFileDescriptor
    /// The path below the mount root, for diagnostics ("/" for the root).
    let path: String

    private init(_ descriptor: consuming OwnedFileDescriptor, path: String) {
        self.descriptor = descriptor
        self.path = path
    }

    var displayPath: String { path == "/" ? Self.mountPoint : Self.mountPoint + path }

    /// Opens /sys/fs/cgroup and requires it to be a cgroup v2 mount.
    static func openRoot() throws -> CgroupDirectory {
        let root: CgroupDirectory
        do {
            root = CgroupDirectory(try Kernel.File.open(mountPoint, .readOnly, options: .directory), path: "/")
        } catch {
            throw RuntimeError("open \(mountPoint): \(error) (cgroup v2 is required)")
        }
        let isCgroup2: Bool
        do {
            isCgroup2 = try root.descriptor.withDescriptor { try Kernel.File.isOnCgroup2($0) }
        } catch {
            throw RuntimeError("inspect \(mountPoint): \(error)")
        }
        guard isCgroup2 else {
            throw RuntimeError("\(mountPoint) is not a cgroup v2 (unified) mount; cgroup v1 and hybrid hierarchies are not supported")
        }
        return root
    }

    /// The existing child cgroup `name`, or nil when it does not exist.
    func child(_ name: String) throws -> CgroupDirectory? {
        let opened: OwnedFileDescriptor
        do {
            opened = try Kernel.File.open(name, in: descriptor, .readOnly, options: [.directory, .noFollow])
        } catch Errno.noSuchFileOrDirectory {
            return nil
        } catch {
            throw RuntimeError("open cgroup \(childPath(name)): \(error)")
        }
        let child = CgroupDirectory(opened, path: childPath(name))
        // A different filesystem mounted over a cgroup directory is not part
        // of the hierarchy.
        guard let own = descriptor.identity(), let other = child.descriptor.identity(), own.device == other.device else {
            throw RuntimeError("cgroup \(child.displayPath) is not on the cgroup v2 mount")
        }
        return child
    }

    /// Creates the child cgroup `name`; false when it already existed.
    func makeChild(_ name: String) throws -> Bool {
        do {
            try descriptor.withDescriptor { try Kernel.File.makeDirectory(name, in: $0, permissions: [.ownerReadWriteExecute, .groupReadExecute, .otherReadExecute]) }
            return true
        } catch Errno.fileExists {
            return false
        } catch {
            throw RuntimeError("create cgroup \(childPath(name)): \(error)")
        }
    }

    /// Removes the empty child cgroup `name`. EBUSY is retried as runc does
    /// (1 ms doubling, 10 retries) while exiting tasks are released.
    /// Returns nil or the error; a missing child counts as removed.
    func removeChild(_ name: String) -> Errno? {
        var delay = Duration.milliseconds(1)
        for attempt in 0...10 {
            let failure: Errno
            do {
                try descriptor.withDescriptor { try Kernel.File.remove(name, in: $0, isDirectory: true) }
                return nil
            } catch {
                failure = (error as? Errno) ?? .badFileDescriptor
            }
            if failure == .noSuchFileOrDirectory { return nil }
            if failure == .interrupted { continue }
            guard failure == .resourceBusy, attempt < 10 else { return failure }
            Kernel.Process.sleep(for: delay)
            delay *= 2
        }
        return .resourceBusy
    }

    /// An interface file's contents, or nil when it does not exist.
    func read(_ file: String) throws -> String? {
        let owner: OwnedFileDescriptor
        do {
            owner = try openInterfaceFile(file, .readOnly)
        } catch Errno.noSuchFileOrDirectory {
            return nil
        } catch {
            throw RuntimeError("open \(displayPath)/\(file): \(error)")
        }
        do {
            return String(decoding: try owner.readAll(limit: 1 << 20), as: UTF8.self)
        } catch let error as Errno where file == "cgroup.procs" && error == .notSupported {
            // Threaded cgroups expose TIDs through cgroup.threads instead,
            // as runc's readProcsFile does after an unsupported procs read.
            return try read("cgroup.threads")
        } catch {
            throw RuntimeError("read \(displayPath)/\(file): \(error)")
        }
    }

    /// Like `read`, but keeps ENOTSUP as an `Errno`, which runc's stats
    /// collection treats as "unavailable" for PSI and cgroup.procs.
    func contents(_ file: String) throws -> String? {
        let owner: OwnedFileDescriptor
        do {
            owner = try openInterfaceFile(file, .readOnly)
        } catch Errno.noSuchFileOrDirectory {
            return nil
        } catch Errno.notSupported {
            throw Errno.notSupported
        } catch {
            throw RuntimeError("open \(displayPath)/\(file): \(error)")
        }
        do {
            return String(decoding: try owner.readAll(limit: 1 << 20), as: UTF8.self)
        } catch let error as Errno where error == .notSupported {
            throw error
        } catch {
            throw RuntimeError("read \(displayPath)/\(file): \(error)")
        }
    }

    /// Writes `text` to an interface file in one write(2), as the kernel
    /// parses each write separately. Returns nil or the error.
    func write(_ file: String, _ text: String) -> Errno? {
        var owner: OwnedFileDescriptor
        do {
            owner = try openInterfaceFile(file, .writeOnly)
        } catch {
            return (error as? Errno) ?? .badFileDescriptor
        }
        defer { try? owner.close() }
        let bytes = Array(text.utf8)
        do {
            let written = try owner.withDescriptor { descriptor in
                try Kernel.File.write(descriptor, bytes.span.bytes)
            }
            return written == bytes.count ? nil : .ioError
        } catch {
            return (error as? Errno) ?? .ioError
        }
    }

    /// Whitespace-separated words of an interface file.
    func words(_ file: String) throws -> [String] {
        (try read(file) ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }

    /// The value of `key` in a flat keyed file such as cgroup.events.
    func keyedValue(_ file: String, _ key: String) throws -> String? {
        for line in (try read(file) ?? "").split(separator: "\n") {
            let fields = line.split(separator: " ")
            if fields.count == 2, fields[0] == key { return String(fields[1]) }
        }
        return nil
    }

    /// Whether any process is in this cgroup or below it.
    func isPopulated() throws -> Bool {
        guard let value = try keyedValue("cgroup.events", "populated") else {
            throw RuntimeError("read \(displayPath)/cgroup.events: no populated entry")
        }
        return value != "0"
    }

    func isFrozen() throws -> Bool {
        try keyedValue("cgroup.events", "frozen") == "1"
    }

    /// Names of child cgroups.
    func subdirectories() throws -> [String] {
        do {
            return try descriptor.directoryEntries(onlyDirectories: true)
        } catch {
            throw RuntimeError("list cgroup \(displayPath): \(error)")
        }
    }

    var inode: UInt64? { descriptor.identity().map { UInt64($0.inode) } }

    /// A new close-on-exec open file description of this directory holding
    /// an exclusive flock, or nil when another one holds it.
    func lockExclusively() throws -> OwnedFileDescriptor? {
        do {
            let lock = try Kernel.File.open(".", in: descriptor, .readOnly, options: .directory)
            while true {
                do {
                    try lock.withDescriptor { try Kernel.File.lock($0, .exclusive) }
                    return lock
                } catch Errno.interrupted {
                    continue
                }
            }
        } catch Errno.wouldBlock {
            return nil
        } catch {
            throw RuntimeError("lock cgroup \(displayPath): \(error)")
        }
    }

    private func childPath(_ name: String) -> String { path == "/" ? "/" + name : path + "/" + name }

    /// An interface file of this cgroup, never through a symbolic link.
    private func openInterfaceFile(_ file: String, _ access: FileDescriptor.AccessMode) throws -> OwnedFileDescriptor {
        try Kernel.File.open(file, in: descriptor, access, options: .noFollow)
    }
}

/// A container's cgroup, prepared by the supervisor before the init exists.
///
/// Path rules follow kontainer-runtime: an absolute `linux.cgroupsPath` is
/// below the mount root, a relative one and the default (the container ID)
/// below `/swift-container-runtime`. Only the controllers configured
/// resources need are enabled in the ancestors' `cgroup.subtree_control`
/// (runc enables every available one), and they are never disabled again,
/// because sibling cgroups may depend on them. Ancestors are never removed.
final class CgroupLeaf {
    let identity: CgroupIdentity
    private let directory: CgroupDirectory
    /// memory.events oom_kill when prepared; an adopted cgroup may already
    /// count earlier kills.
    private let oomKillBaseline: UInt64
    /// The exclusive flock on the leaf held from validation until the init
    /// is a member (or setup fails); empty afterwards.
    private var setupLock: OwnedFileDescriptor

    private init(identity: CgroupIdentity, directory: CgroupDirectory, setupLock: consuming OwnedFileDescriptor) {
        self.identity = identity
        self.directory = directory
        self.oomKillBaseline = Self.oomKillCount(directory)
        self.setupLock = setupLock
    }

    deinit {
        releaseSetupLock()
    }

    /// Creates (or adopts an empty, childless, unfrozen pre-existing) cgroup
    /// and applies the configured limits before any process joins it, so
    /// the init never runs in it without them. Directories created here are
    /// removed again if a later step fails.
    ///
    /// Two containers given the same path are separate runtime processes,
    /// possibly with different state roots, so neither the state lock nor
    /// any in-process lock serializes them: both could see the group empty,
    /// and the later limit writes and join would land in the other's group.
    /// An exclusive nonblocking flock on the leaf directory makes the check
    /// for an unused group, the limit writes, and the init's join one
    /// critical section across processes; the loser fails without writing.
    /// The lock is not held after the join, since membership itself then
    /// marks the group as used.
    static func prepare(_ plan: CgroupPlan, id: ContainerID) throws -> CgroupLeaf {
        let components = plan.components(for: id)
        let resources = plan.resources
        let required = resources.requiredControllers
        let optional = resources.optionalControllers
        let bootID = try ProcFS.bootID()
        let root = try CgroupDirectory.openRoot()
        var made: [(parent: CgroupDirectory, name: String)] = []
        do {
            // Walk down from the root, enabling the required controllers in
            // each parent before entering (or creating) the child.
            var current = root
            var parent = root
            var created = false
            for name in components {
                try enable(required, optional: optional, in: current)
                created = try current.makeChild(name)
                if created { made.append((current, name)) }
                guard let child = try current.child(name) else {
                    throw RuntimeError("cgroup \(current.displayPath)/\(name) disappeared during setup")
                }
                try checkType(child, domain: resources.needsDomainController)
                parent = current
                current = child
            }
            // `created` now describes the leaf, the last component.
            let leaf = current
            let leafName = components.last ?? ""

            // Whoever else holds the lock may already have adopted a leaf
            // this call created, so it is no longer this call's to remove.
            guard let setupLock = try leaf.lockExclusively() else {
                if created { made.removeLast() }
                throw RuntimeError("container's cgroup \(leaf.displayPath) is being set up by another container")
            }
            // Revalidated under the lock: the path still names the opened
            // directory, which nobody joined or populated before the lock.
            guard let reopened = try parent.child(leafName), reopened.inode != nil, reopened.inode == leaf.inode else {
                throw RuntimeError("container's cgroup \(leaf.displayPath) was replaced during setup")
            }
            // A supplied cgroup must be unused: runc refuses a populated or
            // frozen one. Child cgroups are refused too, so everything below
            // the leaf at cleanup was made by this container. A leaf this
            // call created is checked as well, since another container may
            // have adopted it before the lock was taken.
            guard try !leaf.isPopulated() else {
                if created { made.removeLast() }
                throw RuntimeError("container's cgroup \(leaf.displayPath) is not empty: it already has processes")
            }
            guard try leaf.subdirectories().isEmpty else {
                if created { made.removeLast() }
                throw RuntimeError("container's cgroup \(leaf.displayPath) already has child cgroups")
            }
            guard try !leaf.isFrozen() else {
                throw RuntimeError("container's cgroup \(leaf.displayPath) is unexpectedly frozen")
            }

            // Limits in runc's order; a refused value fails setup, except
            // for runc's ignorable swap and its burst retry after cpu.max.
            try apply(resources, to: leaf)
            guard let inode = leaf.inode, inode > 0 else {
                throw RuntimeError("inspect cgroup \(leaf.displayPath): \(Errno.current)")
            }
            let identity = CgroupIdentity(path: leaf.path, inode: inode, bootID: bootID, created: created)
            return CgroupLeaf(identity: identity, directory: leaf, setupLock: setupLock)
        } catch {
            // Remove only what this call created, innermost first.
            for entry in made.reversed() { _ = entry.parent.removeChild(entry.name) }
            throw error
        }
    }

    /// Moves the init into the cgroup through `cgroup.procs`. The caller
    /// guarantees `pid` cannot be reused meanwhile (it is an unreaped child
    /// of a blocked launcher) and that the init has not started setup.
    /// Membership ends the setup lock's critical section.
    func join(_ pid: pid_t) throws {
        if let error = directory.write("cgroup.procs", String(pid)) {
            throw RuntimeError("join container init \(pid) to cgroup \(directory.displayPath): \(error)")
        }
        releaseSetupLock()
    }

    /// The forked init shares the lock's open file description until it
    /// executes (close-on-exec), so closing this copy alone would not
    /// release it; LOCK_UN does, for every copy.
    private func releaseSetupLock() {
        try? setupLock.withDescriptor { Kernel.File.unlock($0) }
        try? setupLock.close()
    }

    /// Whether the kernel OOM-killed a process in this cgroup (or below it)
    /// since it was prepared.
    var oomKilledSincePrepare: Bool { Self.oomKillCount(directory) > oomKillBaseline }

    /// The kernel's OOM kill count (0 without memory.events).
    private static func oomKillCount(_ directory: CgroupDirectory) -> UInt64 {
        (try? directory.keyedValue("memory.events", "oom_kill")).flatMap { UInt64($0) } ?? 0
    }

    /// Enables each missing required controller in `directory`'s subtree.
    /// An unavailable or unwritable required controller is an error, never
    /// skipped; optional ones are attempted and may stay disabled.
    private static func enable(_ controllers: [String], optional: [String], in directory: CgroupDirectory) throws {
        guard !controllers.isEmpty || !optional.isEmpty else { return }
        let enabled = Set(try directory.words("cgroup.subtree_control"))
        for controller in optional where !enabled.contains(controller) {
            _ = directory.write("cgroup.subtree_control", "+" + controller)
        }
        for controller in controllers where !enabled.contains(controller) {
            let available = try directory.words("cgroup.controllers")
            guard available.contains(controller) else {
                throw RuntimeError(
                    "cgroup controller \(controller) is not available in \(directory.displayPath) (cgroup.controllers: \(available.joined(separator: " ")))"
                )
            }
            if let error = directory.write("cgroup.subtree_control", "+" + controller) {
                // A non-root cgroup with member processes cannot enable
                // controllers for its children (no internal processes).
                let members = (try? directory.words("cgroup.procs").count) ?? 0
                let hint = members > 0
                    ? " (it has \(members) member process(es); cgroup v2 enables controllers only for children of a cgroup without processes)"
                    : ""
                throw RuntimeError(
                    "enable cgroup controller \(controller) in \(directory.displayPath)/cgroup.subtree_control: \(error)\(hint)"
                )
            }
        }
    }

    /// runc's fs2 type check. A "domain invalid" cgroup (a child of a
    /// threaded subtree) is switched to threaded when no domain controller
    /// is needed, and refused otherwise; domain controllers are refused in
    /// threaded cgroups too. As in runc, CPU settings count as domain ones.
    private static func checkType(_ directory: CgroupDirectory, domain: Bool) throws {
        let type = (try directory.read("cgroup.type") ?? "domain").trimmingSuffix("\n")
        switch type {
        case "domain invalid":
            if domain {
                throw RuntimeError(
                    "cannot enter cgroup v2 \(directory.displayPath) with domain controllers -- it is in an invalid state"
                )
            }
            // As in runc, a failed switch surfaces when the init joins.
            _ = directory.write("cgroup.type", "threaded")
        case "threaded", "domain threaded":
            if domain {
                throw RuntimeError(
                    "cannot enter cgroup v2 \(directory.displayPath) with domain controllers -- it is in \(type) mode"
                )
            }
        default:
            break
        }
    }

    /// Removes a recorded cgroup. Returns a warning when the path now names
    /// a different cgroup, which is left untouched.
    ///
    /// Remaining processes are killed through `cgroup.kill` (Linux 5.14+)
    /// only when `killRemaining` is set, that is, when they can only be the
    /// container's: its verified init was alive or just exited under this
    /// runtime, or it had no PID namespace (whose members outlive the init;
    /// runc kills them too). Otherwise a populated cgroup is an error. Child
    /// cgroups are removed; the cgroup itself only if this runtime created it.
    static func remove(_ identity: CgroupIdentity, killRemaining: Bool) throws -> String? {
        // An inode from another boot says nothing about the cgroup at the
        // path now, so it is never touched.
        guard try ProcFS.bootID() == identity.bootID else {
            return "cgroup \(CgroupDirectory.mountPoint)\(identity.path) was recorded before a reboot; left untouched"
        }

        // Reopen the recorded path beneath the mount root, without creating.
        let components = identity.components
        var parent = try CgroupDirectory.openRoot()
        var current = parent
        for name in components {
            guard let child = try current.child(name) else { return nil }
            parent = current
            current = child
        }
        guard current.inode == identity.inode else {
            return "cgroup \(current.displayPath) is no longer the container's cgroup; left untouched"
        }

        // Kill whatever remains in the subtree, then wait for it to empty.
        if try current.isPopulated() {
            guard killRemaining else {
                throw RuntimeError(
                    "container's cgroup \(current.displayPath) still has processes that this runtime cannot attribute to the container; they were not killed"
                )
            }
            if let error = current.write("cgroup.kill", "1") {
                let hint = error == .noSuchFileOrDirectory ? " (requires Linux 5.14+)" : ""
                throw RuntimeError("kill processes in cgroup \(current.displayPath) through cgroup.kill: \(error)\(hint)")
            }
            var waited: Int32 = 0
            while try current.isPopulated() {
                guard waited < 10_000 else {
                    throw RuntimeError("processes in cgroup \(current.displayPath) remain 10 seconds after cgroup.kill")
                }
                Kernel.Process.sleep(for: .milliseconds(10))
                waited += 10
            }
        }

        // Remove child cgroups depth-first, then the cgroup if it is ours.
        try removeDescendants(of: current)
        if identity.created {
            if let error = parent.removeChild(components[components.count - 1]) { throw RuntimeError("remove cgroup \(current.displayPath): \(error)") }
        }
        return nil
    }

    /// Exec's child is unreaped and blocked until this write succeeds.
    static func join(_ identity: CgroupIdentity, pid: pid_t) throws {
        guard let directory = try recordedDirectory(identity) else {
            throw RuntimeError("container's recorded cgroup is missing, replaced, or from another boot")
        }
        if let error = directory.write("cgroup.procs", String(pid)) { throw RuntimeError("join exec process to cgroup: \(error)") }
    }

    /// Kill the pinned cgroup subtree atomically, including concurrently
    /// forking descendants. Never fall back to a path or an unpinned PID list.
    static func killAll(_ identity: CgroupIdentity) throws {
        guard let directory = try recordedDirectory(identity) else {
            throw RuntimeError("container's recorded cgroup is missing, replaced, or from another boot")
        }
        if let error = directory.write("cgroup.kill", "1") {
            throw RuntimeError("kill processes in cgroup \(directory.displayPath): \(error) (requires cgroup.kill, Linux 5.14+)")
        }
    }

    /// Opens only this recorded generation, never a replacement or a group
    /// from another boot. Freezer writes use this pinned directory throughout.
    private static func recordedDirectory(_ identity: CgroupIdentity) throws -> CgroupDirectory? {
        guard identity.isValid, try ProcFS.bootID() == identity.bootID else { return nil }
        var directory = try CgroupDirectory.openRoot()
        for name in identity.components {
            guard let child = try directory.child(name) else { return nil }
            directory = child
        }
        return directory.inode == identity.inode ? directory : nil
    }

    /// A nonblocking snapshot of the requested freezer state of this recorded
    /// generation, for waits without the state lock: a concurrent resume or
    /// removal must not stall in `waitFrozen`. Missing, stale or unreadable
    /// groups report false; callers revalidate under the lock.
    static func isFreezeRequested(_ identity: CgroupIdentity) -> Bool {
        guard let directory = try? recordedDirectory(identity) else { return false }
        return (try? directory.read("cgroup.freeze")) == "1\n"
    }

    /// runc checks the requested freezer state, then waits for completion
    /// when freezing. A missing/replaced cgroup cannot make an init paused.
    static func isFrozen(_ identity: CgroupIdentity) throws -> Bool {
        guard let directory = try recordedDirectory(identity),
              try directory.read("cgroup.freeze") == "1\n" else { return false }
        try waitFrozen(directory)
        return true
    }

    /// Called with the cross-process container-state lock held. This is a
    /// synchronous cgroupfs operation, with no await while holding that lock.
    static func setFrozen(_ identity: CgroupIdentity, frozen: Bool) throws {
        guard let directory = try recordedDirectory(identity) else {
            throw RuntimeError("container's recorded cgroup is missing, replaced, or from another boot")
        }
        let value = frozen ? "1" : "0"
        if let error = directory.write("cgroup.freeze", value) {
            throw RuntimeError("set \(directory.displayPath)/cgroup.freeze to \(value): \(error)")
        }
        // A freeze request is asynchronous in the kernel. Readback of 1
        // alone does not prove every task has reached the frozen state.
        guard try directory.read("cgroup.freeze") == value + "\n" else {
            throw RuntimeError("cgroup.freeze did not retain requested state \(value)")
        }
        if frozen { try waitFrozen(directory) }
    }

    /// The leaf must match before controller enablement or limit writes.
    /// Existing ancestors are traversed without creating a new generation.
    static func update(_ identity: CgroupIdentity, resources: CgroupResources) throws {
        guard let leaf = try recordedDirectory(identity) else {
            throw RuntimeError("container's recorded cgroup is missing, replaced, or from another boot")
        }
        var directory = try CgroupDirectory.openRoot()
        var ancestors: [CgroupDirectory] = []
        for name in identity.components {
            ancestors.append(directory)
            guard let child = try directory.child(name) else { throw RuntimeError("container cgroup disappeared during update") }
            directory = child
        }
        guard directory.inode == leaf.inode else { throw RuntimeError("container cgroup was replaced during update") }
        for ancestor in ancestors {
            try enable(resources.requiredControllers, optional: resources.optionalControllers, in: ancestor)
        }
        try checkType(leaf, domain: resources.needsDomainController)
        try apply(resources, to: leaf)
    }

    private static func apply(_ resources: CgroupResources, to directory: CgroupDirectory) throws {
        try resources.apply(in: directory.displayPath, checkMemory: {
            // Checking usage is best effort, as in runc: an unavailable
            // memory.current does not turn a valid limit into an error.
            guard let check = resources.memoryCheck,
                  let text = try? directory.read("memory.current"), let current = UInt64(text.trimmingSuffix("\n")) else { return }
            try check.validate(current: current)
        }) { file, text in directory.write(file, text) }
    }

    /// Includes descendant cgroups, as runc's GetAllPids does. A stale
    /// identity contributes no PIDs from the group now at the recorded path.
    static func processes(_ identity: CgroupIdentity) throws -> [pid_t] {
        guard let directory = try recordedDirectory(identity) else { return [] }
        var pids: [pid_t] = []
        func collect(_ group: CgroupDirectory) throws {
            for field in (try group.read("cgroup.procs") ?? "").split(whereSeparator: { $0.isWhitespace }) {
                guard let pid = pid_t(field), pid > 0 else { throw RuntimeError("invalid PID in cgroup.procs") }
                pids.append(pid)
            }
            for name in try group.subdirectories().sorted() {
                if let child = try group.child(name) { try collect(child) }
            }
        }
        try collect(directory)
        return pids
    }

    /// runc's fs2 statistics for `events --stats`, read from this recorded
    /// generation only.
    static func stats(_ identity: CgroupIdentity) throws -> ContainerStats {
        guard let directory = try recordedDirectory(identity) else {
            throw RuntimeError("container's recorded cgroup is missing, replaced, or from another boot")
        }
        return try directory.stats()
    }

    /// Pins this recorded generation for an event stream; nil when the
    /// cgroup is missing, replaced, or from another boot.
    static func eventSource(_ identity: CgroupIdentity) throws -> CgroupEventSource? {
        try recordedDirectory(identity).map(CgroupEventSource.init)
    }

    private static func waitFrozen(_ directory: CgroupDirectory) throws {
        for _ in 0..<1000 {
            if try directory.keyedValue("cgroup.events", "frozen") == "1" { return }
            Kernel.Process.sleep(for: .milliseconds(10))
        }
        throw RuntimeError("cgroup \(directory.displayPath) did not freeze within 10 seconds")
    }

    private static func removeDescendants(of directory: CgroupDirectory) throws {
        for name in try directory.subdirectories() {
            guard let child = try directory.child(name) else { continue }
            try removeDescendants(of: child)
            if let error = directory.removeChild(name) { throw RuntimeError("remove cgroup \(child.displayPath): \(error)") }
        }
    }
}

/// One pinned cgroup generation observed by `events`. Every read goes
/// through the directory descriptor verified when the stream began, so a
/// cgroup recreated at the same path is never read.
final class CgroupEventSource {
    private let directory: CgroupDirectory

    fileprivate init(_ directory: CgroupDirectory) {
        self.directory = directory
    }

    func stats() throws -> ContainerStats { try directory.stats() }

    /// memory.events oom_kill, or nil when memory.events does not exist
    /// (the memory controller is not enabled for this cgroup).
    func oomKillCount() -> UInt64? {
        guard let text = try? directory.read("memory.events") else { return nil }
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ")
            if fields.count == 2, fields[0] == "oom_kill" { return UInt64(fields[1]) ?? 0 }
        }
        return 0
    }

    /// runc's notifier ends when cgroup.events cannot be read or reports
    /// an empty cgroup, so both count as unpopulated.
    func isPopulated() -> Bool {
        (try? directory.isPopulated()) ?? false
    }

    /// A path naming `file` in the pinned directory through this process's
    /// descriptor table, for inotify_add_watch(2). It names the pinned
    /// generation only while this source is alive.
    func watchPath(_ file: String) throws -> String {
        try directory.descriptor.withDescriptor { "/proc/self/fd/\($0.rawValue)/\(file)" }
    }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}

extension CgroupDirectory {
    /// runc's fs2 Manager.Stats over one directory. Errors are tolerated when
    /// not running as root, as runc does for rootless containers.
    func stats() throws -> ContainerStats {
        try CgroupStatsReader(read: { try self.contents($0) }, hugePageSizes: Self.hugePageSizes()).collect(tolerateErrors: Kernel.Process.effectiveUserID != 0)
    }

    /// runc's HugePageSizes: names from /sys/kernel/mm/hugepages, or none when
    /// the directory cannot be read (no hugetlb support).
    private static func hugePageSizes() -> [String] {
        guard let directory = try? Kernel.File.open("/sys/kernel/mm/hugepages", .readOnly, options: .directory),
              let names = try? directory.directoryEntries() else { return [] }
        return names.compactMap(CgroupFile.hugePageSize(directoryEntry:))
    }
}
