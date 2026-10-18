#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SystemPackage

/// The starter `config.json` written by `spec`, field for field what runc's `specconv.Example`
/// and `ToRootless` produce. It is a write-only model: optional fields are omitted when nil so the
/// JSON has the same keys as runc's. The starter spec asks for features this runtime cannot run yet
/// (a terminal, the /sys/fs/cgroup mount, and the cgroup and user namespaces); they are kept so the output stays a faithful runc starter rather than a reduced one.
/// Nested types and properties mirror the OCI runtime specification's JSON keys of the same names.
public struct DefaultSpecification: Codable, Equatable, Sendable {
    public struct Root: Codable, Equatable, Sendable {
        public var path: String
        public var readonly: Bool?
    }

    public struct User: Codable, Equatable, Sendable {
        public var uid: UInt32
        public var gid: UInt32
    }

    public struct Capabilities: Codable, Equatable, Sendable {
        public var bounding: [String]?
        public var effective: [String]?
        public var permitted: [String]?
    }

    public struct Rlimit: Codable, Equatable, Sendable {
        public var type: String
        public var hard: UInt64
        public var soft: UInt64
    }

    public struct Process: Codable, Equatable, Sendable {
        public var terminal: Bool?
        public var user: User
        public var args: [String]
        public var env: [String]?
        public var cwd: String
        public var capabilities: Capabilities?
        public var rlimits: [Rlimit]?
        public var noNewPrivileges: Bool?
    }

    public struct Mount: Codable, Equatable, Sendable {
        public var destination: String
        public var type: String?
        public var source: String?
        public var options: [String]?
    }

    public struct IDMapping: Codable, Equatable, Sendable {
        public var containerID: UInt32
        public var hostID: UInt32
        public var size: UInt32
    }

    public struct DeviceRule: Codable, Equatable, Sendable {
        public var allow: Bool
        public var access: String?
    }

    public struct Resources: Codable, Equatable, Sendable {
        public var devices: [DeviceRule]?
    }

    public struct Namespace: Codable, Equatable, Sendable {
        public var type: String
    }

    public struct Linux: Codable, Equatable, Sendable {
        public var uidMappings: [IDMapping]?
        public var gidMappings: [IDMapping]?
        public var resources: Resources?
        public var namespaces: [Namespace]?
        public var maskedPaths: [String]?
        public var readonlyPaths: [String]?
    }

    public var ociVersion: String
    public var root: Root?
    public var process: Process?
    public var hostname: String?
    public var mounts: [Mount]?
    public var linux: Linux?

    /// runc's `specconv.Example`. The cgroup namespace is listed only when the host uses the
    /// unified cgroup v2 hierarchy, which the caller probes so this stays a pure function.
    public static func example(cgroupNamespace: Bool) -> DefaultSpecification {
        let capabilities = ["CAP_AUDIT_WRITE", "CAP_KILL", "CAP_NET_BIND_SERVICE"]
        var namespaces = ["pid", "network", "ipc", "uts", "mount"]
        if cgroupNamespace { namespaces.append("cgroup") }
        return DefaultSpecification(
            ociVersion: RuntimeMetadata.ociVersion,
            root: Root(path: "rootfs", readonly: true),
            process: Process(
                terminal: true,
                user: User(uid: 0, gid: 0),
                args: ["sh"],
                env: ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "TERM=xterm"],
                cwd: "/",
                capabilities: Capabilities(bounding: capabilities, effective: capabilities, permitted: capabilities),
                rlimits: [Rlimit(type: "RLIMIT_NOFILE", hard: 1024, soft: 1024)],
                noNewPrivileges: true),
            // runc writes "runc"; this runtime's namespace demo uses "swiftbox".
            hostname: "swiftbox",
            mounts: [
                Mount(destination: "/proc", type: "proc", source: "proc"),
                Mount(destination: "/dev", type: "tmpfs", source: "tmpfs",
                      options: ["nosuid", "strictatime", "mode=755", "size=65536k"]),
                Mount(destination: "/dev/pts", type: "devpts", source: "devpts",
                      options: ["nosuid", "noexec", "newinstance", "ptmxmode=0666", "mode=0620", "gid=5"]),
                Mount(destination: "/dev/shm", type: "tmpfs", source: "shm",
                      options: ["nosuid", "noexec", "nodev", "mode=1777", "size=65536k"]),
                Mount(destination: "/dev/mqueue", type: "mqueue", source: "mqueue",
                      options: ["nosuid", "noexec", "nodev"]),
                Mount(destination: "/sys", type: "sysfs", source: "sysfs",
                      options: ["nosuid", "noexec", "nodev", "ro"]),
                Mount(destination: "/sys/fs/cgroup", type: "cgroup", source: "cgroup",
                      options: ["nosuid", "noexec", "nodev", "relatime", "ro"]),
            ],
            linux: Linux(
                resources: Resources(devices: [DeviceRule(allow: false, access: "rwm")]),
                namespaces: namespaces.map(Namespace.init(type:)),
                maskedPaths: [
                    "/proc/acpi", "/proc/asound", "/proc/kcore", "/proc/keys", "/proc/latency_stats",
                    "/proc/timer_list", "/proc/timer_stats", "/proc/sched_debug", "/sys/firmware", "/proc/scsi",
                ],
                readonlyPaths: ["/proc/bus", "/proc/fs", "/proc/irq", "/proc/sys", "/proc/sysrq-trigger"]))
    }

    /// runc's `specconv.ToRootless`: swap the network namespace for a user namespace mapping
    /// container root to the caller, bind /sys instead of mounting sysfs, drop uid=/gid= mount
    /// options, and remove cgroup resources.
    public func rootless(effectiveUID: UInt32, effectiveGID: UInt32) -> DefaultSpecification {
        var spec = self
        var linux = spec.linux ?? Linux()

        // Namespaces: drop network and any existing user entry, then append user.
        var namespaces = (linux.namespaces ?? []).filter { $0.type != "network" && $0.type != "user" }
        namespaces.append(Namespace(type: "user"))
        linux.namespaces = namespaces
        linux.uidMappings = [IDMapping(containerID: 0, hostID: effectiveUID, size: 1)]
        linux.gidMappings = [IDMapping(containerID: 0, hostID: effectiveGID, size: 1)]
        linux.resources = nil
        spec.linux = linux

        // Mounts: replace /sys (compared after lexical cleaning, like filepath.Clean) and strip
        // ownership options; a mount left with no options omits the key, as runc's does.
        spec.mounts = spec.mounts.map { mounts in
            mounts.map { mount in
                if FilePath(mount.destination).lexicallyNormalized() == FilePath("/sys") {
                    return Mount(destination: "/sys", type: "none", source: "/sys",
                                 options: ["rbind", "nosuid", "noexec", "nodev", "ro"])
                }
                var mount = mount
                let options = (mount.options ?? []).filter { !$0.hasPrefix("gid=") && !$0.hasPrefix("uid=") }
                mount.options = options.isEmpty ? nil : options
                return mount
            }
        }
        return spec
    }

    /// The starter spec for this host and caller, as `spec [--rootless]` writes it.
    public static func forCurrentHost(rootless: Bool) -> DefaultSpecification {
        let spec = example(cgroupNamespace: hostUsesUnifiedCgroupHierarchy())
        return rootless ? spec.rootless(effectiveUID: Kernel.Process.effectiveUserID, effectiveGID: Kernel.Process.effectiveGroupID) : spec
    }

    /// Whether /sys/fs/cgroup is a cgroup2 mount, the check runc uses to add the cgroup namespace.
    /// False off Linux, where the path does not exist.
    public static func hostUsesUnifiedCgroupHierarchy() -> Bool {
        // Opened the same way as Cgroup.swift's mount root.
        guard let root = try? Kernel.File.open("/sys/fs/cgroup", .readOnly, options: .directory) else { return false }
        return (try? root.withDescriptor { try Kernel.File.isOnCgroup2($0) }) ?? false
    }

    /// Indented JSON with sorted keys and a trailing newline.
    public func json() throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return Array(try encoder.encode(self)) + [UInt8(ascii: "\n")]
    }

    /// Writes `config.json` into `bundle` (empty means the current directory, as in runc) without
    /// changing the working directory. O_CREAT|O_EXCL makes the refusal atomic and covers every
    /// existing entry: files, directories, and symlinks, including dangling ones. Mode 0o666 is
    /// filtered by the caller's umask, matching runc's `os.WriteFile`.
    @discardableResult
    public func write(toBundle bundle: String) throws -> FilePath {
        guard !bundle.utf8.contains(0) else { throw RuntimeError("bundle path must not contain NUL") }
        let path = bundle.isEmpty ? FilePath("config.json") : FilePath(bundle).appending("config.json")
        let bytes = try json()

        // Open exclusively; translate the errors a caller can act on.
        let descriptor: FileDescriptor
        do {
            descriptor = try FileDescriptor.open(
                path, .writeOnly, options: [.create, .exclusiveCreate, .closeOnExec],
                permissions: FilePermissions(rawValue: 0o666))
        } catch Errno.fileExists {
            throw RuntimeError("File \(path) exists. Remove it first")
        } catch let error as Errno where error == .noSuchFileOrDirectory || error == .notDirectory {
            throw RuntimeError("bundle \(bundle.isEmpty ? "." : bundle): \(error)")
        } catch {
            throw RuntimeError("create \(path): \(error)")
        }

        // Like runc, a failed write leaves the partial file for the caller to inspect.
        do {
            try descriptor.closeAfter { _ = try descriptor.writeAll(bytes) }
        } catch {
            throw RuntimeError("write \(path): \(error)")
        }
        return path
    }
}
