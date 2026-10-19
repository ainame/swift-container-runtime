/// Which component manages the container's cgroup, chosen by the global
/// `--systemd-cgroup` option at create/run and recorded with the cgroup.
public enum CgroupDriver: Sendable, Equatable {
    /// This runtime creates and removes directories under /sys/fs/cgroup.
    case cgroupfs
    /// systemd creates a transient scope unit with `Delegate=yes`, as runc's
    /// systemd driver for cgroup v2 does; this runtime then writes limits
    /// into the delegated cgroup itself.
    case systemd
}

/// The `slice:prefix:name` form of `linux.cgroupsPath` under the systemd
/// driver, validated as runc's systemd driver parses it. The scope unit is
/// `prefix-name.scope` (or `name.scope` without a prefix) inside the slice.
///
/// An empty path uses `system.slice`, the runtime prefix, and the container
/// ID, as runc defaults to `system.slice` and `runc-<id>.scope`.
public struct SystemdScopeRequest: Sendable, Equatable {
    public let slice: String
    public let prefix: String
    /// Nil: the container ID, known only when the container is created.
    public let name: String?

    /// systemd's unit-name length limit (UNIT_NAME_MAX).
    static let maximumUnitNameLength = 255
    static let defaultSlice = "system.slice"

    init(slice: String, prefix: String, name: String?) {
        self.slice = slice
        self.prefix = prefix
        self.name = name
    }

    /// Parses a nonempty `linux.cgroupsPath` under the systemd driver.
    static func parse(_ path: String) throws -> SystemdScopeRequest {
        let parts = path.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else {
            throw RuntimeError("config.json: linux.cgroupsPath must have the form slice:prefix:name with --systemd-cgroup: \(path)")
        }
        guard !parts[2].isEmpty else {
            throw RuntimeError("config.json: linux.cgroupsPath names no scope with --systemd-cgroup: \(path)")
        }
        // runc turns a name ending in .slice into a slice unit of its own;
        // only scopes are implemented here.
        guard !parts[2].hasSuffix(".slice") else {
            throw RuntimeError("config.json: linux.cgroupsPath names a slice unit, which is not supported; use a scope name: \(path)")
        }
        let request = SystemdScopeRequest(slice: parts[0].isEmpty ? defaultSlice : parts[0], prefix: parts[1], name: parts[2])
        _ = try request.scope(id: nil)
        return request
    }

    /// The scope for container `id`, validated.
    func scope(id: ContainerID?) throws -> SystemdScope {
        let name = self.name ?? id?.rawValue ?? "placeholder"
        let unit = (prefix.isEmpty ? name : prefix + "-" + name) + ".scope"
        guard unit.utf8.count <= Self.maximumUnitNameLength, Self.isValidUnitName(unit) else {
            throw RuntimeError(
                "systemd scope name \(unit.debugDescription) is invalid: unit names allow at most \(Self.maximumUnitNameLength) characters from [A-Za-z0-9:_.-]"
            )
        }
        return SystemdScope(slice: slice, unit: unit, sliceComponents: try Self.expand(slice: slice))
    }

    /// runc's ExpandSlice: `a-b-c.slice` lives at `a.slice/a-b.slice/a-b-c.slice`
    /// and `-.slice` is the root. Dashes separate nonempty levels.
    static func expand(slice: String) throws -> [String] {
        func invalid() -> RuntimeError {
            RuntimeError("systemd slice \(slice.debugDescription) is invalid: it must be -.slice or dash-separated names ending in .slice")
        }
        guard slice.hasSuffix(".slice"), slice.utf8.count <= maximumUnitNameLength, isValidUnitName(slice) else { throw invalid() }
        let base = String(slice.dropLast(".slice".count))
        if base == "-" { return [] }
        let levels = base.split(separator: "-", omittingEmptySubsequences: false)
        guard !levels.contains(where: \.isEmpty) else { throw invalid() }
        var components: [String] = []
        var prefix = ""
        for level in levels {
            prefix = prefix.isEmpty ? String(level) : prefix + "-" + level
            components.append(prefix + ".slice")
        }
        return components
    }

    /// The characters systemd accepts in unit names, without the template
    /// `@` and escape `\` forms, which this runtime never generates.
    private static func isValidUnitName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || ":_.-".unicodeScalars.contains(scalar))
        }
    }
}

/// A validated transient scope: its slice, unit name, and cgroup location.
struct SystemdScope: Sendable, Equatable {
    let slice: String
    let unit: String
    /// The slice's directories below the cgroup v2 mount root.
    let sliceComponents: [String]

    /// The scope's cgroup below the mount root: systemd places a unit's
    /// cgroup in its slice's directory, named after the unit.
    var components: [String] { sliceComponents + [unit] }
}

/// The unit properties systemd stores for the container's resources.
///
/// With `Delegate=yes` this runtime writes the scope's interface files
/// itself, but systemd still owns the scope cgroup's own attributes and
/// rewrites them from its unit state (for example on `daemon-reload`). Like
/// runc's genV2ResourcesProperties, the limits are therefore also given to
/// systemd so a rewrite keeps them. Settings systemd has no property for
/// (`cpu.idle`, `cpu.max.burst`) and device rules (an eBPF program this
/// runtime attaches, which systemd leaves alone) are only written directly.
enum SystemdResourceProperties {
    /// systemd's "infinity" for byte, task and time limits.
    static let infinity = UInt64.max

    static func properties(for resources: CgroupResources) throws -> [(String, DBusValue)] {
        var properties: [(String, DBusValue)] = []
        func limit(_ value: CgroupValue?) -> DBusValue? {
            switch value {
            case .max: .uint64(infinity)
            case let .number(number): .uint64(number)
            default: nil
            }
        }
        if let value = limit(resources.memoryMax) { properties.append(("MemoryMax", value)) }
        if let value = limit(resources.memoryLow) { properties.append(("MemoryLow", value)) }
        if let value = limit(resources.swapMax) { properties.append(("MemorySwapMax", value)) }
        if let value = limit(resources.pidsMax) { properties.append(("TasksMax", value)) }
        if let weight = resources.cpu.weight { properties.append(("CPUWeight", .uint64(weight))) }
        if case let .bandwidth(quota, period) = resources.cpu.max {
            properties.append(("CPUQuotaPerSecUSec", .uint64(quotaPerSecond(quota: quota, period: period))))
            // Requires systemd 242; the period is always explicit in cpu.max.
            properties.append(("CPUQuotaPeriodUSec", .uint64(period)))
        }
        // AllowedCPUs and AllowedMemoryNodes require systemd 244.
        if let cpus = resources.cpuset.cpus, !cpus.isEmpty {
            properties.append(("AllowedCPUs", .array(element: "y", try bitmask(cpus, field: "cpus").map(DBusValue.byte))))
        }
        if let mems = resources.cpuset.mems, !mems.isEmpty {
            properties.append(("AllowedMemoryNodes", .array(element: "y", try bitmask(mems, field: "mems").map(DBusValue.byte))))
        }
        return properties
    }

    /// runc's conversion of quota/period to systemd's per-second quota in
    /// microseconds, rounded up to whole 10 ms because systemd keeps the
    /// value in percent: an unlimited quota is infinity.
    static func quotaPerSecond(quota: Int64?, period: UInt64) -> UInt64 {
        guard let quota, quota > 0, period > 0 else { return infinity }
        let (product, overflow) = UInt64(quota).multipliedReportingOverflow(by: 1_000_000)
        guard !overflow else { return infinity }
        let perSecond = product / period
        return perSecond % 10_000 == 0 ? perSecond : (perSecond / 10_000 + 1) * 10_000
    }

    /// The highest CPU or node number accepted in a list, bounding the mask
    /// a configuration can make this process build.
    static let maximumListEntry = 1 << 16

    /// A kernel list such as `0-3,8` as systemd's byte mask: bit `n % 8`
    /// of byte `n / 8` stands for CPU or node `n`, as runc's RangeToBits.
    static func bitmask(_ list: String, field: String) throws -> [UInt8] {
        func invalid() -> RuntimeError {
            RuntimeError("config.json: linux.resources.cpu.\(field) \(list.debugDescription) is not a list such as 0-3,8")
        }
        var bytes: [UInt8] = []
        for item in list.split(separator: ",") {
            let bounds = item.trimmingSpaces().split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(bounds.count), let low = Int(bounds[0]), let high = Int(bounds[bounds.count - 1]),
                  low >= 0, low <= high, high <= maximumListEntry else { throw invalid() }
            if bytes.count <= high / 8 { bytes += Array(repeating: 0, count: high / 8 + 1 - bytes.count) }
            for number in low...high { bytes[number / 8] |= 1 << (number % 8) }
        }
        guard !bytes.isEmpty else { throw invalid() }
        return bytes
    }
}

extension Substring {
    /// Without leading and trailing spaces, which kernel lists tolerate.
    fileprivate func trimmingSpaces() -> Substring {
        var result = self
        while result.first == " " { result = result.dropFirst() }
        while result.last == " " { result = result.dropLast() }
        return result
    }
}
