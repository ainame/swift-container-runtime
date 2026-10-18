import SystemPackage

/// One value written to a cgroup v2 interface file, formatted as runc
/// formats it.
public enum CgroupValue: Sendable, Equatable, CustomStringConvertible {
    case max
    case number(UInt64)
    /// A signed decimal, such as `cpu.idle`.
    case signed(Int64)
    /// A kernel-parsed CPU or NUMA-node list.
    case list(String)
    /// `cpu.max`: "QUOTA PERIOD", with a nil quota written as `max`.
    case bandwidth(quota: Int64?, period: UInt64)

    public var description: String {
        switch self {
        case .max: "max"
        case let .number(value): String(value)
        case let .signed(value): String(value)
        case let .list(value): value
        case let .bandwidth(quota, period): "\(quota.map { String($0) } ?? "max") \(period)"
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
    /// runc's setCPU defers an EINVAL from `cpu.max.burst` when a quota is
    /// configured and writes the burst again right after `cpu.max`.
    public let retriedAfterCPUMax: Bool

    init(file: String, value: CgroupValue, ignoreMissing: Bool = false, retriedAfterCPUMax: Bool = false) {
        self.file = file
        self.value = value
        self.ignoreMissing = ignoreMissing
        self.retriedAfterCPUMax = retriedAfterCPUMax
    }
}

/// The implemented `linux.resources.cpu` fields, as runc's spec conversion
/// and fs2 setCPU turn them into cgroup v2 writes. Shares, quota, and period
/// of 0 are unset, as absent ones are; a given `idle` or `burst` is always
/// written, 0 included. Values are passed to the kernel unchecked, as runc
/// does, so the kernel's range checks refuse them at create.
public struct CgroupCPU: Sendable, Equatable {
    /// `cpu.idle`.
    public let idle: Int64?
    /// `cpu.weight`, converted from `shares`.
    public let weight: UInt64?
    /// `cpu.max.burst`.
    public let burst: UInt64?
    /// `cpu.max`, whenever quota or period is nonzero: a negative quota is
    /// `max`, and a zero period is the kernel's documented default 100000.
    public let max: CgroupValue?
    /// A nonzero quota, which allows the burst retry: the kernel checks a
    /// new burst against the current quota, which `cpu.max` is about to
    /// replace. A zero quota with a period writes `max` but does not retry.
    public let hasQuota: Bool

    public static let none = CgroupCPU(idle: nil, weight: nil, burst: nil, max: nil, hasQuota: false)

    /// runc's isCPUSet.
    public var isSet: Bool { idle != nil || weight != nil || burst != nil || max != nil }

    /// setCPU's order: idle, weight, burst, then `cpu.max`.
    var writes: [CgroupWrite] {
        var writes: [CgroupWrite] = []
        if let idle { writes.append(CgroupWrite(file: "cpu.idle", value: .signed(idle))) }
        if let weight { writes.append(CgroupWrite(file: "cpu.weight", value: .number(weight))) }
        if let burst {
            writes.append(CgroupWrite(file: "cpu.max.burst", value: .number(burst), retriedAfterCPUMax: hasQuota))
        }
        if let max { writes.append(CgroupWrite(file: "cpu.max", value: max)) }
        return writes
    }
}

/// CPU and NUMA-node lists. Empty strings leave the existing values alone;
/// the kernel parses nonempty lists and determines the effective inherited set.
public struct CgroupCpuset: Sendable, Equatable {
    public let cpus: String?
    public let mems: String?

    public static let none = CgroupCpuset(cpus: nil, mems: nil)
    public var isSet: Bool { cpus != nil || mems != nil }

    /// runc writes CPUs before memory nodes, after the CPU bandwidth files.
    var writes: [CgroupWrite] {
        var result: [CgroupWrite] = []
        if let cpus { result.append(CgroupWrite(file: "cpuset.cpus", value: .list(cpus))) }
        if let mems { result.append(CgroupWrite(file: "cpuset.mems", value: .list(mems))) }
        return result
    }
}

/// The implemented subset of `linux.resources`, converted to cgroup v2 file
/// values as runc's fs2 driver does. Each controller preserves its own
/// absent, zero, and empty-value semantics.
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
    /// `cpu.idle`, `cpu.weight`, `cpu.max.burst`, and `cpu.max`.
    public let cpu: CgroupCPU
    public let cpuset: CgroupCpuset
    let memoryCheck: MemoryUsageCheck?
    let devicePolicy: DevicePolicy?

    public static let none = CgroupResources(memoryMax: nil, memoryLow: nil, swapMax: nil, pidsMax: nil)

    init(memoryMax: CgroupValue?, memoryLow: CgroupValue?, swapMax: CgroupValue?, pidsMax: CgroupValue?, cpu: CgroupCPU = .none, cpuset: CgroupCpuset = .none, memoryCheck: MemoryUsageCheck? = nil, devicePolicy: DevicePolicy? = nil) {
        self.memoryMax = memoryMax
        self.memoryLow = memoryLow
        self.swapMax = swapMax
        self.pidsMax = pidsMax
        self.cpu = cpu
        self.cpuset = cpuset
        self.memoryCheck = memoryCheck
        self.devicePolicy = devicePolicy
    }

    /// Writes in runc's Set order: pids, then memory.swap.max, memory.max,
    /// and memory.low, then CPU files in setCPU's order and cpuset lists.
    public var writes: [CgroupWrite] {
        var writes: [CgroupWrite] = []
        if let pidsMax { writes.append(CgroupWrite(file: "pids.max", value: pidsMax, ignoreMissing: false)) }
        if let swapMax {
            let ignorable = swapMax == .max || swapMax == .number(0)
            writes.append(CgroupWrite(file: "memory.swap.max", value: swapMax, ignoreMissing: ignorable))
        }
        if let memoryMax { writes.append(CgroupWrite(file: "memory.max", value: memoryMax, ignoreMissing: false)) }
        if let memoryLow { writes.append(CgroupWrite(file: "memory.low", value: memoryLow, ignoreMissing: false)) }
        writes += cpu.writes
        writes += cpuset.writes
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
        if cpu.isSet { controllers.append("cpu") }
        if cpuset.isSet { controllers.append("cpuset") }
        return controllers
    }

    /// Controllers enabled when available, whose failure is not an error:
    /// memory for an ignorable swap write that is the only memory setting.
    public var optionalControllers: [String] {
        swapMax != nil && !requiredControllers.contains("memory") ? ["memory"] : []
    }

    /// Whether every cgroup on the path must be a plain domain: runc's
    /// containsDomainController, which counts any memory file and, although
    /// the kernel's cpu controller is threaded, any CPU setting.
    var needsDomainController: Bool { memoryMax != nil || memoryLow != nil || swapMax != nil || cpu.isSet }

    /// Performs `writes` in order through `write`, which returns nil or the
    /// error, and throws at the first refusal. A deferred burst (see
    /// `CgroupWrite.retriedAfterCPUMax`) is written once more right after
    /// `cpu.max` succeeds, and its second refusal is the error.
    func apply(in displayPath: String, checkMemory: () throws -> Void = {}, write: (_ file: String, _ text: String) -> Errno?) throws {
        func failure(_ item: CgroupWrite, _ error: Errno) -> RuntimeError {
            let hint = error == .noSuchFileOrDirectory
                ? " (the controller file does not exist in this kernel or cgroup)" : ""
            return RuntimeError("set \(displayPath)/\(item.file) to \(item.value): \(error)\(hint)")
        }
        var deferred: (item: CgroupWrite, error: Errno)?
        var checkedMemory = false
        for item in writes {
            if !checkedMemory && item.file.hasPrefix("memory.") {
                try checkMemory()
                checkedMemory = true
            }
            guard let error = write(item.file, item.value.description) else {
                if item.file == "cpu.max", let retry = deferred {
                    deferred = nil
                    if let again = write(retry.item.file, retry.item.value.description) { throw failure(retry.item, again) }
                }
                continue
            }
            if error == .noSuchFileOrDirectory && item.ignoreMissing { continue }
            if error == .invalidArgument && item.retriedAfterCPUMax && deferred == nil {
                deferred = (item, error)
                continue
            }
            throw failure(item, error)
        }
        // A retried burst always precedes a `cpu.max` write; never drop it.
        if let deferred { throw failure(deferred.item, deferred.error) }
    }
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

    /// runc's value semantics. A memory value below -1 is rejected here;
    /// runc passes it to the kernel, which refuses it at create.
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

        // CPU: runc rejects no value. Shares become a weight (0 stays
        // unset); any nonzero quota or period writes cpu.max, any negative
        // quota as max and a zero period as 100000; idle and burst are
        // written whenever given.
        let cpu = resources?.cpu
        let weight = cpuWeight(shares: cpu?.shares ?? 0)
        let quota = cpu?.quota ?? 0
        let period = cpu?.period ?? 0
        let cpuMax: CgroupValue? = quota == 0 && period == 0
            ? nil : .bandwidth(quota: quota > 0 ? quota : nil, period: period == 0 ? 100_000 : period)
        let cpuValues = CgroupCPU(
            idle: cpu?.idle, weight: weight == 0 ? nil : weight, burst: cpu?.burst, max: cpuMax, hasQuota: quota != 0
        )
        // runc leaves empty cpuset strings untouched; nonempty lists are
        // passed through to the kernel, including its syntax/range checks.
        let cpuset = CgroupCpuset(
            cpus: cpu?.cpus.flatMap { $0.isEmpty ? nil : $0 },
            mems: cpu?.mems.flatMap { $0.isEmpty ? nil : $0 }
        )
        return CgroupResources(memoryMax: memoryMax, memoryLow: memoryLow, swapMax: swapMax, pidsMax: pidsMax, cpu: cpuValues, cpuset: cpuset,
            memoryCheck: memory?.checkBeforeUpdate == true && (limit > 0 || swap > 0) ? MemoryUsageCheck(limit: limit, swap: swap) : nil,
            devicePolicy: try resources?.devices.flatMap { $0.isEmpty ? nil : try DevicePolicy($0) }
        )
    }

    /// runc's ConvertCPUSharesToCgroupV2Value: a quadratic in log2(shares)
    /// through shares 2, 1024, and 262144 to weights 1, 100, and 10000,
    /// rounded up. 0 means unset.
    static func cpuWeight(shares: UInt64) -> UInt64 {
        if shares == 0 { return 0 }
        if shares <= 2 { return 1 }
        if shares >= 262_144 { return 10_000 }
        let l = Kernel.Math.log2(Double(shares))
        let exponent = (l * l + 125 * l) / 612.0 - 7.0 / 34.0
        return UInt64(Kernel.Math.power(10, exponent).rounded(.up))
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
    /// Only this program is detached when an adopted cgroup is cleaned up.
    var deviceProgramID: UInt32? = nil

    var components: [String] { path.split(separator: "/").map(String.init) }

    /// Rejects anything a malformed record could use to reach the mount
    /// root or leave the hierarchy.
    var isValid: Bool {
        let parts = components
        return path.hasPrefix("/") && inode > 0 && !parts.isEmpty
            && !path.utf8.contains(0) && !path.utf8.contains(UInt8(ascii: "\n"))
            && !parts.contains { $0 == "." || $0 == ".." }
            && InitIdentity.isValidBootID(bootID)
            && (deviceProgramID.map { $0 > 0 } ?? true)
    }
}
