#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import LinuxAPI
import SystemPackage

/// One directory of the cgroup v2 hierarchy, opened beneath the mount root
/// one component at a time without following symlinks, so a path can never
/// leave the hierarchy. Interface files are opened relative to it.
private final class CgroupDirectory {
    static let mountPoint = "/sys/fs/cgroup"
    /// CGROUP2_SUPER_MAGIC from <linux/magic.h>.
    static let cgroup2Magic: Int64 = 0x6367_7270
    /// DT_DIR from <dirent.h>, identical on every Linux architecture.
    static let directoryType: UInt8 = 4

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
        let raw = unsafe linux_open_at(AT_FDCWD, mountPoint, O_RDONLY | O_DIRECTORY, 0)
        guard raw >= 0 else { throw RuntimeError("open \(mountPoint): \(Errno(rawValue: errno)) (cgroup v2 is required)") }
        let root = CgroupDirectory(OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw)), path: "/")
        var status = statfs()
        let result = (try? root.descriptor.withDescriptor { unsafe fstatfs($0.rawValue, &status) }) ?? -1
        guard result == 0 else { throw RuntimeError("inspect \(mountPoint): \(Errno(rawValue: errno))") }
        guard Int64(status.f_type) == cgroup2Magic else {
            throw RuntimeError("\(mountPoint) is not a cgroup v2 (unified) mount; cgroup v1 and hybrid hierarchies are not supported")
        }
        return root
    }

    /// The existing child cgroup `name`, or nil when it does not exist.
    func child(_ name: String) throws -> CgroupDirectory? {
        let raw = try descriptor.withDescriptor { unsafe linux_open_at($0.rawValue, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW, 0) }
        guard raw >= 0 else {
            if errno == ENOENT { return nil }
            throw RuntimeError("open cgroup \(childPath(name)): \(Errno(rawValue: errno))")
        }
        let child = CgroupDirectory(OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw)), path: childPath(name))
        // A different filesystem mounted over a cgroup directory is not part
        // of the hierarchy.
        guard let own = fileIdentity(descriptor), let other = fileIdentity(child.descriptor), own.device == other.device else {
            throw RuntimeError("cgroup \(child.displayPath) is not on the cgroup v2 mount")
        }
        return child
    }

    /// Creates the child cgroup `name`; false when it already existed.
    func makeChild(_ name: String) throws -> Bool {
        let result = try descriptor.withDescriptor { unsafe mkdirat($0.rawValue, name, 0o755) }
        if result == 0 { return true }
        if errno == EEXIST { return false }
        throw RuntimeError("create cgroup \(childPath(name)): \(Errno(rawValue: errno))")
    }

    /// Removes the empty child cgroup `name`. EBUSY is retried as runc does
    /// (1 ms doubling, 10 retries) while exiting tasks are released.
    /// Returns 0 or errno; a missing child counts as removed.
    func removeChild(_ name: String) -> Int32 {
        var delay: Int32 = 1
        for attempt in 0...10 {
            let result = (try? descriptor.withDescriptor { unsafe unlinkat($0.rawValue, name, AT_REMOVEDIR) }) ?? -1
            if result == 0 { return 0 }
            let code = errno
            if code == ENOENT { return 0 }
            if code == EINTR { continue }
            guard code == EBUSY, attempt < 10 else { return code }
            sleep(milliseconds: delay)
            delay *= 2
        }
        return EBUSY
    }

    /// An interface file's contents, or nil when it does not exist.
    func read(_ file: String) throws -> String? {
        let raw = try descriptor.withDescriptor { unsafe linux_open_at($0.rawValue, file, O_RDONLY | O_NOFOLLOW, 0) }
        guard raw >= 0 else {
            if errno == ENOENT { return nil }
            throw RuntimeError("open \(displayPath)/\(file): \(Errno(rawValue: errno))")
        }
        let owner = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
        do {
            return String(decoding: try owner.readAll(limit: 1 << 20), as: UTF8.self)
        } catch {
            throw RuntimeError("read \(displayPath)/\(file): \(error)")
        }
    }

    /// Writes `text` to an interface file in one write(2), as the kernel
    /// parses each write separately. Returns 0 or errno.
    func write(_ file: String, _ text: String) -> Int32 {
        let raw = (try? descriptor.withDescriptor { unsafe linux_open_at($0.rawValue, file, O_WRONLY | O_NOFOLLOW, 0) }) ?? -1
        guard raw >= 0 else { return errno }
        var owner = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
        defer { try? owner.close() }
        let bytes = Array(text.utf8)
        do {
            let written = try owner.withDescriptor { descriptor in
                try bytes.withUnsafeBytes { buffer in unsafe try descriptor.write(buffer) }
            }
            return written == bytes.count ? 0 : EIO
        } catch let error as Errno {
            return error.rawValue
        } catch {
            return EIO
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
        let raw = try descriptor.withDescriptor { unsafe linux_open_at($0.rawValue, ".", O_RDONLY | O_DIRECTORY, 0) }
        guard raw >= 0 else { throw RuntimeError("list cgroup \(displayPath): \(Errno(rawValue: errno))") }
        // fdopendir takes ownership of the new descriptor; closedir closes it.
        guard let stream = unsafe fdopendir(raw) else {
            let code = errno
            _ = close(raw)
            throw RuntimeError("list cgroup \(displayPath): \(Errno(rawValue: code))")
        }
        defer { _ = unsafe closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = unsafe readdir(stream) else {
                guard errno == 0 else { throw RuntimeError("list cgroup \(displayPath): \(Errno(rawValue: errno))") }
                return names
            }
            guard unsafe entry.pointee.d_type == Self.directoryType else { continue }
            let name = unsafe withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                unsafe String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
    }

    var inode: UInt64? { fileIdentity(descriptor).map { UInt64($0.inode) } }

    /// A new close-on-exec open file description of this directory holding
    /// an exclusive flock, or nil when another one holds it.
    func lockExclusively() throws -> OwnedFileDescriptor? {
        let raw = try descriptor.withDescriptor { unsafe linux_open_at($0.rawValue, ".", O_RDONLY | O_DIRECTORY, 0) }
        guard raw >= 0 else { throw RuntimeError("lock cgroup \(displayPath): \(Errno(rawValue: errno))") }
        let lock = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
        while true {
            let result = try lock.withDescriptor { flock($0.rawValue, LOCK_EX | LOCK_NB) }
            if result == 0 { return lock }
            if errno == EINTR { continue }
            if errno == EWOULDBLOCK { return nil }
            throw RuntimeError("lock cgroup \(displayPath): \(Errno(rawValue: errno))")
        }
    }

    private func childPath(_ name: String) -> String { path == "/" ? "/" + name : path + "/" + name }
}

private func sleep(milliseconds: Int32) {
    _ = poll(nil, 0, milliseconds)
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
        let bootID = try currentBootID()
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
            try resources.apply(in: leaf.displayPath) { file, text in leaf.write(file, text) }
            guard let inode = leaf.inode, inode > 0 else {
                throw RuntimeError("inspect cgroup \(leaf.displayPath): \(Errno(rawValue: errno))")
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
        let code = directory.write("cgroup.procs", String(pid))
        guard code == 0 else {
            throw RuntimeError("join container init \(pid) to cgroup \(directory.displayPath): \(Errno(rawValue: code))")
        }
        releaseSetupLock()
    }

    /// The forked init shares the lock's open file description until it
    /// executes (close-on-exec), so closing this copy alone would not
    /// release it; LOCK_UN does, for every copy.
    private func releaseSetupLock() {
        _ = try? setupLock.withDescriptor { flock($0.rawValue, LOCK_UN) }
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
            let code = directory.write("cgroup.subtree_control", "+" + controller)
            guard code == 0 else {
                // A non-root cgroup with member processes cannot enable
                // controllers for its children (no internal processes).
                let members = (try? directory.words("cgroup.procs").count) ?? 0
                let hint = members > 0
                    ? " (it has \(members) member process(es); cgroup v2 enables controllers only for children of a cgroup without processes)"
                    : ""
                throw RuntimeError(
                    "enable cgroup controller \(controller) in \(directory.displayPath)/cgroup.subtree_control: \(Errno(rawValue: code))\(hint)"
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
        guard try currentBootID() == identity.bootID else {
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
            let code = current.write("cgroup.kill", "1")
            guard code == 0 else {
                let hint = code == ENOENT ? " (requires Linux 5.14+)" : ""
                throw RuntimeError("kill processes in cgroup \(current.displayPath) through cgroup.kill: \(Errno(rawValue: code))\(hint)")
            }
            var waited: Int32 = 0
            while try current.isPopulated() {
                guard waited < 10_000 else {
                    throw RuntimeError("processes in cgroup \(current.displayPath) remain 10 seconds after cgroup.kill")
                }
                sleep(milliseconds: 10)
                waited += 10
            }
        }

        // Remove child cgroups depth-first, then the cgroup if it is ours.
        try removeDescendants(of: current)
        if identity.created {
            let code = parent.removeChild(components[components.count - 1])
            guard code == 0 else { throw RuntimeError("remove cgroup \(current.displayPath): \(Errno(rawValue: code))") }
        }
        return nil
    }

    /// Opens only this recorded generation, never a replacement or a group
    /// from another boot. Freezer writes use this pinned directory throughout.
    private static func recordedDirectory(_ identity: CgroupIdentity) throws -> CgroupDirectory? {
        guard identity.isValid, try currentBootID() == identity.bootID else { return nil }
        var directory = try CgroupDirectory.openRoot()
        for name in identity.components {
            guard let child = try directory.child(name) else { return nil }
            directory = child
        }
        return directory.inode == identity.inode ? directory : nil
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
        let code = directory.write("cgroup.freeze", value)
        guard code == 0 else {
            throw RuntimeError("set \(directory.displayPath)/cgroup.freeze to \(value): \(Errno(rawValue: code))")
        }
        // A freeze request is asynchronous in the kernel. Readback of 1
        // alone does not prove every task has reached the frozen state.
        guard try directory.read("cgroup.freeze") == value + "\n" else {
            throw RuntimeError("cgroup.freeze did not retain requested state \(value)")
        }
        if frozen { try waitFrozen(directory) }
    }

    private static func waitFrozen(_ directory: CgroupDirectory) throws {
        for _ in 0..<1000 {
            if try directory.keyedValue("cgroup.events", "frozen") == "1" { return }
            sleep(milliseconds: 10)
        }
        throw RuntimeError("cgroup \(directory.displayPath) did not freeze within 10 seconds")
    }

    private static func removeDescendants(of directory: CgroupDirectory) throws {
        for name in try directory.subdirectories() {
            guard let child = try directory.child(name) else { continue }
            try removeDescendants(of: child)
            let code = directory.removeChild(name)
            guard code == 0 else { throw RuntimeError("remove cgroup \(child.displayPath): \(Errno(rawValue: code))") }
        }
    }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
#endif
