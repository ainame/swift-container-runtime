/// One value written to a cgroup v2 limit file: `max` or a decimal number.
public enum CgroupValue: Sendable, Equatable, CustomStringConvertible {
    case max
    case number(UInt64)

    public var description: String {
        switch self {
        case .max: "max"
        case let .number(value): String(value)
        }
    }
}

/// One write to a cgroup v2 interface file in the container's cgroup.
public struct CgroupWrite: Sendable, Equatable {
    public let file: String
    public let value: CgroupValue
    /// runc ignores a missing `memory.swap.max` (swap accounting disabled)
    /// when it would only write `max` or `0`.
    public let ignoreMissing: Bool
}

/// The implemented subset of `linux.resources`, converted to cgroup v2 file
/// values exactly as runc's fs2 driver does. Absent and zero values are
/// "unset" (nothing is written), as in runc's Resources.
public struct CgroupResources: Sendable, Equatable {
    /// `memory.max`, from `memory.limit`.
    public let memoryMax: CgroupValue?
    /// `memory.low`, from `memory.reservation`.
    public let memoryLow: CgroupValue?
    /// `memory.swap.max`: OCI `memory.swap` is memory+swap, cgroup v2 swap
    /// is separate, so runc's ConvertMemorySwapToCgroupV2Value applies.
    public let swapMax: CgroupValue?
    /// `pids.max`, from `pids.limit`.
    public let pidsMax: CgroupValue?

    public static let none = CgroupResources(memoryMax: nil, memoryLow: nil, swapMax: nil, pidsMax: nil)

    /// Writes in runc's Set order: pids, then memory.swap.max, memory.max,
    /// and memory.low.
    public var writes: [CgroupWrite] {
        var writes: [CgroupWrite] = []
        if let pidsMax { writes.append(CgroupWrite(file: "pids.max", value: pidsMax, ignoreMissing: false)) }
        if let swapMax {
            let ignorable = swapMax == .max || swapMax == .number(0)
            writes.append(CgroupWrite(file: "memory.swap.max", value: swapMax, ignoreMissing: ignorable))
        }
        if let memoryMax { writes.append(CgroupWrite(file: "memory.max", value: memoryMax, ignoreMissing: false)) }
        if let memoryLow { writes.append(CgroupWrite(file: "memory.low", value: memoryLow, ignoreMissing: false)) }
        return writes
    }

    /// Controllers that must be enabled down to the container's cgroup for
    /// `writes` to succeed. An ignorable swap write (`max` or `0`) alone does
    /// not require memory: runc succeeds without `memory.swap.max` then.
    public var requiredControllers: [String] {
        var controllers: [String] = []
        let swapRequired = swapMax != nil && swapMax != .max && swapMax != .number(0)
        if memoryMax != nil || memoryLow != nil || swapRequired { controllers.append("memory") }
        if pidsMax != nil { controllers.append("pids") }
        return controllers
    }

    /// Controllers enabled when available, whose failure is not an error:
    /// memory for an ignorable swap write that is the only memory setting.
    public var optionalControllers: [String] {
        swapMax != nil && !requiredControllers.contains("memory") ? ["memory"] : []
    }

    /// Whether any memory file is written. Memory is a domain controller,
    /// so every cgroup on the path must then be a plain domain.
    var needsDomainController: Bool { memoryMax != nil || memoryLow != nil || swapMax != nil }
}

/// `linux.cgroupsPath` plus resources. A container always gets its own
/// cgroup, as in runc and kontainer-runtime: absent paths use a default.
public struct CgroupPlan: Sendable, Equatable {
    /// How `linux.cgroupsPath` was given.
    public enum Location: Sendable, Equatable {
        /// Absent or empty: `/swift-container-runtime/<container ID>`.
        case runtimeDefault
        /// Relative: below `/swift-container-runtime`, as kontainer-runtime
        /// nests relative paths below its own prefix.
        case relative([String])
        /// Absolute: relative to the cgroup v2 mount root.
        case absolute([String])
    }

    /// The runtime's subtree below the cgroup v2 mount root.
    public static let runtimePrefix = "swift-container-runtime"
    static let maximumComponentBytes = 255
    static let maximumPathBytes = 4095
    static let maximumComponents = 64

    public let location: Location
    public let resources: CgroupResources

    public init(location: Location, resources: CgroupResources) {
        self.location = location
        self.resources = resources
    }

    /// Components below the mount root for `id`; never empty.
    public func components(for id: ContainerID) -> [String] {
        switch location {
        case .runtimeDefault: [Self.runtimePrefix, id.rawValue]
        case let .relative(parts): [Self.runtimePrefix] + parts
        case let .absolute(parts): parts
        }
    }

    /// Validates `linux.cgroupsPath` and `linux.resources`.
    static func validated(path: String?, resources: OCIConfiguration.Resources?) throws -> CgroupPlan {
        CgroupPlan(location: try location(path), resources: try converted(resources))
    }

    /// Unlike runc, which cleans `.` and `..` lexically, such components are
    /// rejected, and an absolute path must name a cgroup below the mount
    /// root: runc would place the container in the root cgroup itself.
    static func location(_ path: String?) throws -> Location {
        guard let path, !path.isEmpty else { return .runtimeDefault }
        guard !path.utf8.contains(0), !path.utf8.contains(UInt8(ascii: "\n")) else {
            throw RuntimeError("config.json: linux.cgroupsPath must not contain NUL or newline")
        }
        guard path.utf8.count <= maximumPathBytes else {
            throw RuntimeError("config.json: linux.cgroupsPath exceeds \(maximumPathBytes) bytes")
        }
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else {
            throw RuntimeError("config.json: linux.cgroupsPath must not contain . or .. components: \(path)")
        }
        guard !parts.isEmpty else {
            throw RuntimeError("config.json: linux.cgroupsPath must name a cgroup below the cgroup v2 root, not the root itself")
        }
        guard parts.count <= maximumComponents else {
            throw RuntimeError("config.json: linux.cgroupsPath exceeds \(maximumComponents) components")
        }
        guard parts.allSatisfy({ $0.utf8.count <= maximumComponentBytes }) else {
            throw RuntimeError("config.json: linux.cgroupsPath components must not exceed \(maximumComponentBytes) bytes")
        }
        return path.hasPrefix("/") ? .absolute(parts) : .relative(parts)
    }

    /// runc's value semantics. A value below -1 is rejected here; runc
    /// passes it to the kernel, which refuses it at create.
    static func converted(_ resources: OCIConfiguration.Resources?) throws -> CgroupResources {
        // Memory: 0 (or absent) is unset, -1 is "max", positive is bytes.
        func memoryValue(_ value: Int64, field: String) throws -> CgroupValue? {
            switch value {
            case 0: return nil
            case -1: return .max
            case 1...: return .number(UInt64(value))
            default:
                throw RuntimeError(
                    "config.json: linux.resources.memory.\(field) must be -1 (unlimited), 0 (unset), or a positive byte count: \(value)"
                )
            }
        }
        let memory = resources?.memory
        let limit = memory?.limit ?? 0
        let swap = memory?.swap ?? 0
        let memoryMax = try memoryValue(limit, field: "limit")
        let memoryLow = try memoryValue(memory?.reservation ?? 0, field: "reservation")
        _ = try memoryValue(swap, field: "swap")
        let swapMax = try convertSwap(memorySwap: swap, memory: limit)

        // pids: runc writes "max" for any negative value and remaps 0 to 1
        // (systemd's TasksMax cannot be 0); an absent limit keeps the value.
        let pidsMax: CgroupValue? = resources?.pids?.limit.map { value in
            value > 0 ? .number(UInt64(value)) : value == 0 ? .number(1) : .max
        }
        return CgroupResources(memoryMax: memoryMax, memoryLow: memoryLow, swapMax: swapMax, pidsMax: pidsMax)
    }

    /// runc's ConvertMemorySwapToCgroupV2Value followed by its setMemory
    /// rule: when memory+swap equals memory, swap is disabled with "0".
    /// Inputs are already known to be -1 or above.
    static func convertSwap(memorySwap: Int64, memory: Int64) throws -> CgroupValue? {
        let field = "config.json: linux.resources.memory.swap"
        switch true {
        case memory == -1 && memorySwap == 0:
            // Unlimited memory without swap means unlimited swap too.
            return .max
        case memorySwap == -1:
            return .max
        case memorySwap == 0:
            return nil
        case memory == -1:
            return .number(UInt64(memorySwap))
        case memory == 0:
            throw RuntimeError("\(field): unable to set swap limit without memory limit")
        case memorySwap < memory:
            throw RuntimeError("\(field): memory+swap limit should be >= memory limit (\(memorySwap) < \(memory))")
        default:
            return .number(UInt64(memorySwap - memory))
        }
    }
}

/// The cgroup a container was placed in, persisted with its state so later
/// commands can clean it up. The inode (the kernel's cgroup ID, never reused
/// within a boot) distinguishes this cgroup from a later one at the same
/// path, so a stale record never touches a different generation. Inodes are
/// only unique within one boot, so the boot ID is recorded too and must
/// match before the cgroup is touched.
struct CgroupIdentity: Codable, Sendable, Equatable {
    /// Absolute path below the cgroup v2 mount root.
    var path: String
    var inode: UInt64
    /// /proc/sys/kernel/random/boot_id when the cgroup was prepared.
    var bootID: String
    /// True when this container created the directory and removes it on
    /// cleanup; a supplied pre-existing cgroup is emptied and left in place.
    var created: Bool

    var components: [String] { path.split(separator: "/").map(String.init) }

    /// Rejects anything a malformed record could use to reach the mount
    /// root or leave the hierarchy.
    var isValid: Bool {
        let parts = components
        return path.hasPrefix("/") && inode > 0 && !parts.isEmpty
            && !path.utf8.contains(0) && !path.utf8.contains(UInt8(ascii: "\n"))
            && !parts.contains { $0 == "." || $0 == ".." }
            && isValidBootID(bootID)
    }
}
