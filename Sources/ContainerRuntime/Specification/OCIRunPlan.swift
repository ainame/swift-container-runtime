import SystemPackage

/// A container ID with runc's accepted character set. Lifecycle commands use
/// it as a single directory name below the state root.
public struct ContainerID: Sendable, Equatable {
    /// The ID as given.
    public let rawValue: String

    /// - Throws: `RuntimeError` unless `rawValue` has 1...1024 characters from
    ///   `[A-Za-z0-9_+.-]` and is not `.` or `..`.
    public init(_ rawValue: String) throws {
        let allowed = rawValue.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || "_+-.".unicodeScalars.contains(scalar))
        }
        guard !rawValue.isEmpty, rawValue.utf8.count <= 1024, allowed, rawValue != ".", rawValue != ".." else {
            throw RuntimeError("container ID must be 1...1024 characters from [A-Za-z0-9_+.-] and not '.' or '..'")
        }
        self.rawValue = rawValue
    }
}

/// A validated, immutable description of one foreground OCI run.
///
/// Building a plan performs every check that does not need the container's
/// mount namespace. Path *resolution* inside the rootfs happens later, from a
/// rootfs descriptor, so that symlinks in the bundle cannot redirect setup.
public struct OCIRunPlan: Sendable {
    /// A namespace the container gets newly created (`linux.namespaces`).
    public enum Namespace: String, Sendable, CaseIterable {
        case pid, mount, uts, ipc, network
    }

    /// Filesystems and bind operations a configured mount may use.
    public enum FilesystemType: String, Sendable {
        case proc, tmpfs, devpts, sysfs, mqueue, bind
    }

    /// The supported mount options that map to mount flags.
    public struct MountFlags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let nosuid = MountFlags(rawValue: 1 << 0)
        public static let nodev = MountFlags(rawValue: 1 << 1)
        public static let noexec = MountFlags(rawValue: 1 << 2)
        public static let strictatime = MountFlags(rawValue: 1 << 3)
        public static let readonly = MountFlags(rawValue: 1 << 4)
    }

    /// The propagation a bind clone is given before it is attached.
    public enum BindPropagation: Sendable, Equatable {
        /// `private`: the clone's top mount only.
        case `private`
        /// `rprivate`: the clone and every mount below it.
        case recursivePrivate
    }

    /// One validated entry of `mounts`.
    public struct Mount: Sendable, Equatable {
        public let type: FilesystemType
        /// A filesystem source label, or an absolute host path for a bind.
        public let source: String
        /// Destination components below the rootfs, without `.` or `..`.
        public let destination: [String]
        public let flags: MountFlags
        /// Flags explicitly cleared (for example rw or exec) on a bind clone.
        public let clearedFlags: MountFlags
        /// `rbind`: the bind also clones every mount below its source.
        public let recursiveBind: Bool
        /// nil keeps the private launch namespace's default propagation.
        public let propagation: BindPropagation?
        /// Comma-separated filesystem data (for example `mode=755`).
        public let data: String

        /// The destination as an absolute container path.
        public var destinationPath: String { "/" + destination.joined(separator: "/") }
    }

    /// `process.user` and `process.noNewPrivileges`, applied in the init
    /// before the workload can execute.
    public struct ProcessSecurity: Sendable, Equatable {
        /// The workload's user ID.
        public let uid: UInt32
        /// The workload's primary group ID.
        public let gid: UInt32
        /// Replaces the caller's supplementary groups; empty clears them.
        public let additionalGids: [UInt32]
        /// Defaults to 0o022 as in runc, not to the caller's mask.
        public let umask: UInt32
        /// Sets no_new_privs, so exec can never gain privileges.
        public let noNewPrivileges: Bool

        /// Linux's NGROUPS_MAX.
        static let maximumAdditionalGids = 65_536
        /// `(uid_t)-1` means "unchanged" to the kernel's set*id calls.
        static let unchangedID = UInt32.max
    }

    /// The configuration's `ociVersion`, a 1.x version.
    public let ociVersion: String
    /// The resolved absolute bundle directory.
    public let bundle: FilePath
    /// The resolved absolute root filesystem directory.
    public let rootfs: FilePath
    /// `root.readonly`: after setup, the container's root mount (not its
    /// child mounts, and not the host's mount of the rootfs) is read-only.
    public let readonlyRoot: Bool
    /// Recorded in container state; they do not affect setup.
    public let annotations: [String: String]
    /// The namespaces created for the container; others are inherited or joined.
    public let namespaces: [Namespace]
    /// A supplied network namespace to join; nil creates one only when listed
    /// in namespaces. Supplied paths must be absolute host paths.
    public let networkNamespacePath: String?
    /// The UTS hostname; nil keeps the inherited one.
    public let hostname: String?
    /// `linux.sysctl`, validated against the container's namespaces and
    /// applied in key order after `pivot_root`.
    public let sysctls: [Sysctl]
    /// The configured mounts, in order.
    public let mounts: [Mount]
    /// True when a tmpfs is mounted at /dev; the runtime then creates the
    /// standard device nodes and /dev symlinks inside it.
    public let populatesDev: Bool
    /// `process.args`: the workload command and its arguments.
    public let arguments: [String]
    /// The complete workload environment; nothing is inherited from the caller.
    public let environment: [String]
    /// Where the init looks for arguments[0].
    let executable: ExecutableLookup
    /// Components of process.cwd below the container root.
    public let cwd: [String]
    /// Initial OOM policy, reused for exec independently of process-file overrides.
    public let oomScoreAdjustment: Int32?
    /// Syscall policy applied to init and persisted for every exec.
    let seccomp: SeccompProfile?
    /// AppArmor and SELinux contexts for init, recorded for every exec.
    let securityLabels: SecurityLabels
    /// `process.terminal`; requires a detached launch with `--console-socket`.
    public let terminal: Bool
    /// The terminal's initial size, when both dimensions are nonzero.
    let consoleSize: OCIConfiguration.ConsoleSize?
    /// The workload's user, groups, umask and no_new_privs.
    public let security: ProcessSecurity
    /// `process.capabilities`; nil leaves the inherited sets, as in runc.
    public let capabilities: ProcessCapabilities?
    /// `process.rlimits` in input order, repeats included; empty inherits all.
    public let resourceLimits: [ResourceLimit]
    /// `linux.readonlyPaths` and `linux.maskedPaths`, applied in that order
    /// after the container root is final.
    public let pathControls: PathControls
    /// `linux.cgroupsPath` and the implemented `linux.resources` subset.
    /// Every container gets its own cgroup v2 group, as in runc.
    public let cgroup: CgroupPlan
    /// Raw values must survive bundle removal: future updates distinguish
    /// omitted settings from defaults and merge quota/period independently.
    let resourceConfiguration: OCIConfiguration.Resources

    /// Loads `config.json` from a bundle directory and resolves the rootfs.
    public static func load(bundle: FilePath) throws -> OCIRunPlan {
        let bundle = try BundleConfiguration.resolveDirectory(bundle, role: "bundle")
        let bytes = try BundleConfiguration.read(bundle.appending("config.json"))
        let configuration = try OCIConfiguration.decode(bytes)
        // Check before constructing a FilePath: an embedded NUL would truncate it.
        let rootString = configuration.root.path
        guard !rootString.isEmpty, !rootString.utf8.contains(0) else {
            throw RuntimeError("config.json: root.path must be non-empty and contain no NUL")
        }
        let rootPath = FilePath(rootString)
        let rootfs = try BundleConfiguration.resolveDirectory(rootPath.isAbsolute ? rootPath : bundle.pushing(rootPath), role: "root.path")
        return try OCIRunPlan(configuration, bundle: bundle, rootfs: rootfs)
    }

    /// Like runc's command-based exec, reread the bundle's process settings.
    /// The live root and namespaces are pinned separately by the lifecycle.
    static func loadExec(
        bundle: FilePath, arguments: [String], environment: [String], cwd: String?, user: String?,
        additionalGids: [UInt32] = [], noNewPrivileges: Bool? = nil, capabilities: [String] = [],
        processFile: FilePath? = nil, terminal: Bool = false
    ) throws -> OCIProcessPlan {
        if let processFile {
            return try OCIProcessPlan(OCIConfiguration.decodeProcess(BundleConfiguration.read(processFile)))
        }
        var configuration = try OCIConfiguration.decode(BundleConfiguration.read(bundle.appending("config.json")))
        configuration.process.args = arguments
        configuration.process.terminal = terminal
        configuration.process.env = (configuration.process.env ?? []) + environment
        if let cwd { configuration.process.cwd = cwd }
        if let user {
            let pieces = user.split(separator: ":", omittingEmptySubsequences: false)
            guard pieces.count == 1 || pieces.count == 2,
                  let uid = UInt32(pieces[0]), uid != UInt32.max else {
                throw RuntimeError("exec --user must be a numeric uid[:gid]")
            }
            // A missing OCI user defaults to root just as it does for run.
            if configuration.process.user == nil {
                configuration.process.user = OCIConfiguration.User()
            }
            configuration.process.user?.uid = uid
            if pieces.count == 2 {
                guard let gid = UInt32(pieces[1]), gid != UInt32.max else {
                    throw RuntimeError("exec --user must be a numeric uid[:gid]")
                }
                configuration.process.user?.gid = gid
            }
        }
        // As runc's getProcess: groups are appended to the configured ones
        // (validated with them below), and no_new_privs changes only when given.
        if !additionalGids.isEmpty {
            var staged = configuration.process.user ?? OCIConfiguration.User()
            staged.additionalGids = (staged.additionalGids ?? []) + additionalGids
            configuration.process.user = staged
        }
        if let noNewPrivileges { configuration.process.noNewPrivileges = noNewPrivileges }
        if !capabilities.isEmpty {
            configuration.process.capabilities = try execCapabilities(configuration.process.capabilities, adding: capabilities)
        }
        return try OCIProcessPlan(configuration.process)
    }

    /// runc's getProcess appends each --cap to bounding, effective, and
    /// permitted, never to inheritable, and to ambient only when inheritable
    /// is present (even empty). runc then only warns when raising an ambient
    /// capability fails, which PR_CAP_AMBIENT_RAISE does for one that is not
    /// inheritable; appending only those that are inheritable keeps runc's
    /// resulting sets without tripping the strict ambient check. Unknown names
    /// are rejected, as for config.json. A missing object, which runc would
    /// dereference as nil, starts empty: the process then has only the
    /// requested capabilities instead of the inherited ones.
    static func execCapabilities(
        _ configured: OCIConfiguration.Capabilities?, adding names: [String]
    ) throws -> OCIConfiguration.Capabilities {
        for name in names where CapabilitySet.number(named: name) == nil {
            throw RuntimeError("exec --cap: unknown capability \"\(name)\"; names are exact, such as CAP_CHOWN")
        }
        var staged = configured ?? OCIConfiguration.Capabilities()
        staged.bounding = (staged.bounding ?? []) + names
        staged.effective = (staged.effective ?? []) + names
        staged.permitted = (staged.permitted ?? []) + names
        if let inheritable = staged.inheritable {
            staged.ambient = (staged.ambient ?? []) + names.filter(inheritable.contains)
        }
        return staged
    }

    /// Runs the workload in the foreground without any container state, and
    /// waits for it. Like `NamespaceCommand.run`, this rejects multithreaded
    /// callers. A default-path cgroup gets a name unique to this run and is
    /// removed whenever the run ends.
    ///
    /// - Returns: The workload's shell-style ``ExitStatus``: its exit code
    ///   (0...255), or 128 plus the signal number when a signal killed it.
    ///   Signal interpretation is conventional: an explicit exit code can
    ///   have the same value.
    /// - Throws: `RuntimeError` when setup fails before the workload runs.
    @available(*, noasync, message: "launch containers before starting async work")
    public func run() throws -> ExitStatus {
        // A transient ID from this process and a monotonic timestamp, so a
        // leftover group of an earlier run with a reused PID is not adopted.
        let now = Kernel.Process.monotonicTime()
        let id = try ContainerID("transient-\(Kernel.Process.id)-\(now.seconds)-\(now.nanoseconds)")
        let leaf = try CgroupLeaf.prepare(cgroup, id: id)

        // The init has exited (or never started) when runOnLinux returns, so
        // whatever remains in the cgroup belongs to this run.
        var hooks = LaunchHooks()
        hooks.placeInit = { try leaf.join($0) }
        let status: Int32
        do {
            status = try runOnLinux(hooks: hooks)
        } catch {
            _ = try? CgroupLeaf.remove(leaf.identity, killRemaining: true)
            throw leaf.oomKilledSincePrepare ? RuntimeError("container init was OOM-killed (memory limit too low?): \(error)") : error
        }
        if let warning = try CgroupLeaf.remove(leaf.identity, killRemaining: true) {
            RuntimeDiagnostics.writeError("swift-container-runtime: warning: \(warning)")
        }
        return ExitStatus(shellStatus: status)
    }

    init(_ configuration: OCIConfiguration, bundle: FilePath, rootfs: FilePath) throws {
        guard bundle.isAbsolute, rootfs.isAbsolute else {
            throw RuntimeError("bundle and rootfs paths must be absolute")
        }
        guard rootfs != FilePath("/") else {
            throw RuntimeError("config.json: root.path must not resolve to the host root directory")
        }
        let version = configuration.ociVersion
        guard version.hasPrefix("1."), version.split(separator: ".").count >= 2 else {
            throw RuntimeError("config.json: unsupported ociVersion \(version); expected 1.x")
        }
        let process = try OCIProcessPlan(configuration.process)
        // SELinux mount contexts need context= data on every mount, which
        // this runtime does not add. Refuse rather than drop the request.
        if let label = configuration.linux.mountLabel, !label.isEmpty {
            throw RuntimeError("config.json: linux.mountLabel is not implemented; remove it or use an empty label")
        }

        var namespaces = Set<Namespace>()
        var seenNamespaces = Set<Namespace>()
        var networkNamespacePath: String?
        for entry in configuration.linux.namespaces {
            guard let namespace = Namespace(rawValue: entry.type) else {
                throw RuntimeError("config.json: namespace type \(entry.type) is not implemented; supported: pid, mount, uts, ipc, network")
            }
            guard seenNamespaces.insert(namespace).inserted else {
                throw RuntimeError("config.json: duplicate \(entry.type) namespace")
            }
            if let path = entry.path, !path.isEmpty {
                guard namespace == .network else {
                    throw RuntimeError("config.json: \(entry.type) namespace path is not implemented; only network paths may be joined")
                }
                guard !path.utf8.contains(0) else { throw RuntimeError("config.json: network namespace path must not contain NUL") }
                let file = FilePath(path)
                guard file.isAbsolute else { throw RuntimeError("config.json: network namespace path must be absolute") }
                networkNamespacePath = path
            } else {
                namespaces.insert(namespace)
            }
        }
        guard namespaces.contains(.mount) else {
            throw RuntimeError("config.json: a mount namespace is required for pivot_root")
        }
        switch configuration.linux.rootfsPropagation {
        case nil, "private", "rprivate": break
        case let other?:
            throw RuntimeError("config.json: linux.rootfsPropagation \(other) is not implemented; only rprivate is used")
        }

        if let hostname = configuration.hostname {
            guard namespaces.contains(.uts) else {
                throw RuntimeError("config.json: hostname requires a uts namespace")
            }
            do { try NamespaceCommand.validateHostname(hostname) } catch {
                throw RuntimeError("config.json: \(error)")
            }
        }

        let mounts = try configuration.mounts.enumerated().map { index, mount in
            try Self.mount(mount, index: index, namespaces: namespaces, bundle: bundle)
        }
        let sysctls = try Sysctl.validated(
            configuration.linux.sysctl ?? [:], creating: namespaces, joinsNetwork: networkNamespacePath != nil)
        // Written through the container's own procfs, which must be mounted.
        if !sysctls.isEmpty, !mounts.contains(where: { $0.type == .proc && $0.destination == ["proc"] }) {
            throw RuntimeError("config.json: linux.sysctl needs a proc mount at /proc")
        }
        let pathControls = try PathControls(
            readonly: configuration.linux.readonlyPaths ?? [], masked: configuration.linux.maskedPaths ?? []
        )
        let cgroup = try CgroupPlan.validated(path: configuration.linux.cgroupsPath, resources: configuration.linux.resources)

        self.ociVersion = version
        self.bundle = bundle
        self.rootfs = rootfs
        self.readonlyRoot = configuration.root.readonly ?? false
        self.annotations = configuration.annotations
        self.namespaces = Namespace.allCases.filter(namespaces.contains)
        self.networkNamespacePath = networkNamespacePath
        self.seccomp = configuration.linux.seccomp
        self.securityLabels = process.securityLabels
        self.terminal = process.terminal
        self.consoleSize = process.consoleSize
        self.oomScoreAdjustment = process.oomScoreAdjustment
        self.hostname = configuration.hostname
        self.sysctls = sysctls
        self.mounts = mounts
        self.populatesDev = mounts.last(where: { $0.destination == ["dev"] })?.type == .tmpfs
        self.arguments = process.arguments
        self.environment = process.environment
        self.executable = process.executable
        self.cwd = process.cwd
        self.security = process.security
        self.capabilities = process.capabilities
        self.resourceLimits = process.resourceLimits
        self.pathControls = pathControls
        self.cgroup = cgroup
        resourceConfiguration = configuration.linux.resources ?? OCIConfiguration.Resources()
    }

    /// An absent `process.user` means uid and gid 0, as in runc. Values the
    /// kernel would treat specially or silently truncate are rejected.
    static func security(_ process: OCIConfiguration.Process) throws -> ProcessSecurity {
        let user = process.user
        let uid = user?.uid ?? 0, gid = user?.gid ?? 0
        let additionalGids = user?.additionalGids ?? []
        let unchanged = ProcessSecurity.unchangedID
        guard uid != unchanged, gid != unchanged, !additionalGids.contains(unchanged) else {
            throw RuntimeError("config.json: process.user IDs must be below \(unchanged), which means 'unchanged' to Linux")
        }
        guard additionalGids.count <= ProcessSecurity.maximumAdditionalGids else {
            throw RuntimeError("config.json: process.user.additionalGids exceeds \(ProcessSecurity.maximumAdditionalGids) entries")
        }
        let umask = user?.umask ?? 0o022
        guard umask <= 0o777 else {
            throw RuntimeError("config.json: process.user.umask 0\(String(umask, radix: 8)) has bits outside 0777")
        }
        return ProcessSecurity(
            uid: uid, gid: gid, additionalGids: additionalGids, umask: umask,
            noNewPrivileges: process.noNewPrivileges ?? false
        )
    }

    /// Validates every entry, then keeps the last occurrence of each name in
    /// the order of those occurrences, as runc's prepareEnv does.
    static func environment(_ entries: [String]) throws -> [String] {
        // Names are compared as bytes, as Linux does. String equality would
        // merge canonically equivalent but distinct names (é vs e + U+0301).
        var names: [[UInt8]] = []
        for entry in entries {
            let bytes = Array(entry.utf8)
            guard let separator = bytes.firstIndex(of: UInt8(ascii: "=")), separator != 0, !bytes.contains(0) else {
                throw RuntimeError("config.json: process.env entry must have the form NAME=value without NUL: \(entry)")
            }
            names.append(Array(bytes[..<separator]))
        }
        var seen = Set<[UInt8]>()
        var kept: [String] = []
        for (name, entry) in zip(names, entries).reversed() where seen.insert(name).inserted {
            kept.append(entry)
        }
        return kept.reversed()
    }

    private static func mount(_ mount: OCIConfiguration.Mount, index: Int, namespaces: Set<Namespace>, bundle: FilePath) throws -> Mount {
        let field = "mounts[\(index)]"
        guard !(mount.source ?? "").utf8.contains(0) else {
            throw RuntimeError("config.json: \(field).source must not contain NUL")
        }
        let options = mount.options ?? []
        // A bind/rbind option defines the operation even with OCI type none.
        let binds = options.contains("bind") || options.contains("rbind")
        guard let type = binds ? .bind : mount.type.flatMap(FilesystemType.init(rawValue:)) else {
            throw RuntimeError("config.json: \(field).type \(mount.type ?? "<missing>") is not implemented; supported: proc, tmpfs, devpts, sysfs, mqueue, bind")
        }
        if type == .bind, mount.source?.isEmpty != false {
            throw RuntimeError("config.json: \(field).source is required for a bind mount")
        }
        let destination = try components(mount.destination, field: "\(field).destination")
        guard !destination.isEmpty else {
            throw RuntimeError("config.json: \(field).destination must not be /")
        }
        switch type {
        case .proc:
            guard destination == ["proc"] else { throw RuntimeError("config.json: \(field): proc is only supported at /proc") }
            guard namespaces.contains(.pid) else {
                throw RuntimeError("config.json: \(field): proc requires a pid namespace in this runtime")
            }
        case .devpts:
            guard destination == ["dev", "pts"] else { throw RuntimeError("config.json: \(field): devpts is only supported at /dev/pts") }
        case .bind:
            guard destination.first != "proc" else {
                throw RuntimeError("config.json: \(field): bind mounts over /proc are not implemented")
            }
        case .tmpfs, .sysfs, .mqueue:
            break
        }

        var flags: MountFlags = []
        var cleared: MountFlags = []
        var recursiveBind = false
        var propagation: BindPropagation?
        var data: [String] = []
        for option in options {
            switch option {
            case "nosuid": flags.insert(.nosuid); cleared.remove(.nosuid)
            case "nodev": flags.insert(.nodev); cleared.remove(.nodev)
            case "noexec": flags.insert(.noexec); cleared.remove(.noexec)
            case "suid": flags.remove(.nosuid); cleared.insert(.nosuid)
            case "dev": flags.remove(.nodev); cleared.insert(.nodev)
            case "exec": flags.remove(.noexec); cleared.insert(.noexec)
            case "strictatime": flags.insert(.strictatime)
            case "ro": flags.insert(.readonly); cleared.remove(.readonly)
            case "rw": flags.remove(.readonly); cleared.insert(.readonly)
            case "bind" where type == .bind: break
            case "rbind" where type == .bind: recursiveBind = true
            case "private" where type == .bind: propagation = .private
            case "rprivate" where type == .bind: propagation = .recursivePrivate
            default:
                guard isSupportedData(option, for: type) else {
                    throw RuntimeError("config.json: \(field).options \(option) is not implemented for \(type.rawValue)")
                }
                data.append(option)
            }
        }
        if type == .tmpfs, destination == ["dev"], flags.contains(.nodev) {
            throw RuntimeError("config.json: \(field): nodev on /dev would make the created device nodes unusable")
        }
        let source: String
        if type == .bind, let path = mount.source {
            let file = FilePath(path)
            source = (file.isAbsolute ? file : bundle.pushing(file)).string
        } else {
            source = mount.source ?? type.rawValue
        }
        return Mount(type: type, source: source, destination: destination, flags: flags,
                     clearedFlags: cleared, recursiveBind: recursiveBind, propagation: propagation,
                     data: data.joined(separator: ","))
    }

    private static func isSupportedData(_ option: String, for type: FilesystemType) -> Bool {
        let parts = option.split(separator: "=", maxSplits: 1).map(String.init)
        guard let key = parts.first else { return false }
        let octal = { (value: String) in !value.isEmpty && value.count <= 4 && value.allSatisfy { ("0"..."7").contains($0) } }
        let decimal = { (value: String) in !value.isEmpty && value.count <= 18 && value.allSatisfy(\.isASCII) && value.allSatisfy(\.isNumber) }
        switch (type, key, parts.count) {
        case (.tmpfs, "mode", 2): return octal(parts[1])
        case (.tmpfs, "size", 2):
            var value = parts[1]
            if let unit = value.last, "kmg".contains(unit) { value.removeLast() }
            return decimal(value)
        case (.devpts, "newinstance", 1): return true
        case (.devpts, "ptmxmode", 2), (.devpts, "mode", 2): return octal(parts[1])
        case (.devpts, "gid", 2): return decimal(parts[1])
        default: return false
        }
    }

    /// Supported limits for container paths. Setup resolves one component per
    /// recursion level, so the component bound also bounds stack depth.
    static let maximumPathComponents = 128
    static let maximumPathBytes = 4095

    /// Splits an absolute container path into components. `.` and `..` are
    /// rejected rather than normalized; this is a lexical check only, and
    /// symlink safety comes from descriptor-relative resolution at setup.
    static func components(_ path: String, field: String) throws -> [String] {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw RuntimeError("config.json: \(field) must be an absolute path without NUL: \(path)")
        }
        guard path.utf8.count <= maximumPathBytes else {
            throw RuntimeError("config.json: \(field) exceeds \(maximumPathBytes) bytes")
        }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count <= maximumPathComponents else {
            throw RuntimeError("config.json: \(field) exceeds \(maximumPathComponents) components")
        }
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else {
            throw RuntimeError("config.json: \(field) must not contain . or .. components: \(path)")
        }
        return parts
    }
}
