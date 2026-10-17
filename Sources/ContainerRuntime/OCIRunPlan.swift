#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import SystemPackage

/// A container ID with runc's accepted character set. Lifecycle commands use
/// it as a single directory name below the state root.
public struct ContainerID: Sendable, Equatable {
    public let rawValue: String

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
    public enum Namespace: String, Sendable, CaseIterable {
        case pid, mount, uts, ipc, network
    }

    public enum FilesystemType: String, Sendable {
        case proc, tmpfs, devpts
    }

    public struct MountFlags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let nosuid = MountFlags(rawValue: 1 << 0)
        public static let nodev = MountFlags(rawValue: 1 << 1)
        public static let noexec = MountFlags(rawValue: 1 << 2)
        public static let strictatime = MountFlags(rawValue: 1 << 3)
    }

    public struct Mount: Sendable, Equatable {
        public let type: FilesystemType
        public let source: String
        /// Destination components below the rootfs, without `.` or `..`.
        public let destination: [String]
        public let flags: MountFlags
        /// Comma-separated filesystem data (for example `mode=755`).
        public let data: String

        public var destinationPath: String { "/" + destination.joined(separator: "/") }
    }

    /// `process.user` and `process.noNewPrivileges`, applied in the init
    /// before the workload can execute.
    public struct ProcessSecurity: Sendable, Equatable {
        public let uid: UInt32
        public let gid: UInt32
        /// Replaces the caller's supplementary groups; empty clears them.
        public let additionalGids: [UInt32]
        /// Defaults to 0o022 as in runc, not to the caller's mask.
        public let umask: UInt32
        public let noNewPrivileges: Bool

        /// Linux's NGROUPS_MAX.
        static let maximumAdditionalGids = 65_536
        /// `(uid_t)-1` means "unchanged" to the kernel's set*id calls.
        static let unchangedID = UInt32.max
    }

    public let ociVersion: String
    public let bundle: FilePath
    public let rootfs: FilePath
    /// Recorded in container state; they do not affect setup.
    public let annotations: [String: String]
    public let namespaces: [Namespace]
    public let hostname: String?
    public let mounts: [Mount]
    /// True when a tmpfs is mounted at /dev; the runtime then creates the
    /// standard device nodes and /dev symlinks inside it.
    public let populatesDev: Bool
    public let arguments: [String]
    /// The complete workload environment; nothing is inherited from the caller.
    public let environment: [String]
    /// Components of process.cwd below the container root.
    public let cwd: [String]
    public let security: ProcessSecurity

    /// Loads `config.json` from a bundle directory and resolves the rootfs.
    public static func load(bundle: FilePath) throws -> OCIRunPlan {
        let bundle = try canonicalDirectory(bundle, role: "bundle")
        let bytes = try readConfiguration(bundle.appending("config.json"))
        let configuration = try OCIConfiguration.decode(bytes)
        // Check before constructing a FilePath: an embedded NUL would truncate it.
        let rootString = configuration.root.path
        guard !rootString.isEmpty, !rootString.utf8.contains(0) else {
            throw RuntimeError("config.json: root.path must be non-empty and contain no NUL")
        }
        let rootPath = FilePath(rootString)
        let rootfs = try canonicalDirectory(rootPath.isAbsolute ? rootPath : bundle.pushing(rootPath), role: "root.path")
        return try OCIRunPlan(configuration, bundle: bundle, rootfs: rootfs)
    }

    /// Runs the workload in the foreground and returns its shell-style exit
    /// status. Like `NamespaceCommand.run`, this rejects multithreaded callers.
    @available(*, noasync, message: "launch containers before starting async work")
    public func run() throws -> Int32 {
        #if os(Linux)
        return try runOnLinux()
        #else
        throw RuntimeError("OCI run requires Linux")
        #endif
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
        guard configuration.root.readonly != true else {
            throw RuntimeError("config.json: root.readonly is not implemented")
        }

        let process = configuration.process
        guard process.terminal != true else {
            throw RuntimeError("config.json: process.terminal is not implemented; use terminal: false")
        }
        let security = try Self.security(process)
        guard let executable = process.args.first, executable.hasPrefix("/") else {
            throw RuntimeError("config.json: process.args[0] must be an absolute path; PATH lookup is not implemented")
        }
        guard process.args.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw RuntimeError("config.json: process.args must not contain NUL")
        }
        let environment = try Self.environment(process.env ?? [])
        let cwd = try Self.components(process.cwd, field: "process.cwd")

        var namespaces = Set<Namespace>()
        for entry in configuration.linux.namespaces {
            guard let namespace = Namespace(rawValue: entry.type) else {
                throw RuntimeError("config.json: namespace type \(entry.type) is not implemented; supported: pid, mount, uts, ipc, network")
            }
            guard namespaces.insert(namespace).inserted else {
                throw RuntimeError("config.json: duplicate \(entry.type) namespace")
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
            do { try validateHostname(hostname) } catch {
                throw RuntimeError("config.json: \(error)")
            }
        }

        let mounts = try configuration.mounts.enumerated().map { index, mount in
            try Self.mount(mount, index: index, namespaces: namespaces)
        }

        self.ociVersion = version
        self.bundle = bundle
        self.rootfs = rootfs
        self.annotations = configuration.annotations
        self.namespaces = Namespace.allCases.filter(namespaces.contains)
        self.hostname = configuration.hostname
        self.mounts = mounts
        self.populatesDev = mounts.contains { $0.type == .tmpfs && $0.destination == ["dev"] }
        self.arguments = process.args
        self.environment = environment
        self.cwd = cwd
        self.security = security
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

    private static func mount(_ mount: OCIConfiguration.Mount, index: Int, namespaces: Set<Namespace>) throws -> Mount {
        let field = "mounts[\(index)]"
        guard !(mount.source ?? "").utf8.contains(0) else {
            throw RuntimeError("config.json: \(field).source must not contain NUL")
        }
        guard let typeName = mount.type, let type = FilesystemType(rawValue: typeName) else {
            throw RuntimeError("config.json: \(field).type \(mount.type ?? "<missing>") is not implemented; supported: proc, tmpfs, devpts")
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
        case .tmpfs:
            break
        }

        var flags: MountFlags = []
        var data: [String] = []
        for option in mount.options ?? [] {
            switch option {
            case "nosuid": flags.insert(.nosuid)
            case "nodev": flags.insert(.nodev)
            case "noexec": flags.insert(.noexec)
            case "strictatime": flags.insert(.strictatime)
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
        return Mount(type: type, source: mount.source ?? type.rawValue, destination: destination, flags: flags, data: data.joined(separator: ","))
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

/// Resolves symlinks and confirms the result is a directory. Paths that do
/// not round-trip through String are rejected, because launch strings are
/// built from `FilePath.string` and would otherwise be silently repaired.
private func canonicalDirectory(_ path: FilePath, role: String) throws -> FilePath {
    let resolved: FilePath = unsafe try path.withPlatformString { input in
        guard let output = unsafe realpath(input, nil) else {
            throw RuntimeError("resolve \(role) \(path): \(Errno(rawValue: errno))")
        }
        defer { unsafe free(output) }
        return unsafe FilePath(platformString: output)
    }
    guard FilePath(resolved.string) == resolved else {
        throw RuntimeError("\(role) \(resolved) is not valid UTF-8, which this runtime does not support")
    }
    do {
        let descriptor = try FileDescriptor.open(resolved, .readOnly, options: [.directory, .closeOnExec])
        var owner = OwnedFileDescriptor(takingOwnershipOf: descriptor)
        try owner.close()
    } catch {
        throw RuntimeError("\(role) \(resolved) is not an accessible directory: \(error)")
    }
    return resolved
}

private func readConfiguration(_ path: FilePath) throws -> [UInt8] {
    let limit = 1 << 20
    let owner: OwnedFileDescriptor
    do {
        owner = OwnedFileDescriptor(takingOwnershipOf: try FileDescriptor.open(path, .readOnly, options: .closeOnExec))
    } catch {
        throw RuntimeError("open \(path): \(error)")
    }
    do {
        return try owner.withDescriptor { descriptor in
            var bytes: [UInt8] = []
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = try chunk.withUnsafeMutableBytes { buffer in
                    unsafe try descriptor.read(into: buffer)
                }
                if count == 0 { return bytes }
                bytes += chunk[..<count]
                guard bytes.count <= limit else { throw RuntimeError("\(path) exceeds 1 MiB") }
            }
        }
    } catch let error as RuntimeError {
        throw error
    } catch {
        throw RuntimeError("read \(path): \(error)")
    }
}
