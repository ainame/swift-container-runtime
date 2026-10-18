import SystemPackage

/// runc's PSIData: averages are percentages, total is microseconds.
struct PSIData: Equatable, Sendable {
    var avg10 = 0.0
    var avg60 = 0.0
    var avg300 = 0.0
    var total: UInt64 = 0
}

struct PSIStats: Equatable, Sendable {
    var some = PSIData()
    var full = PSIData()
}

/// runc's MemoryEntry. cgroup v2 never reports a failcnt.
struct MemoryEntry: Equatable, Sendable {
    var limit: UInt64 = 0
    var usage: UInt64 = 0
    var max: UInt64 = 0
    var failcnt: UInt64 = 0

    var isZero: Bool { limit == 0 && usage == 0 && max == 0 && failcnt == 0 }
}

struct BlkioEntry: Equatable, Sendable {
    var major: UInt64
    var minor: UInt64
    var op: String
    var value: UInt64
}

/// runc's Hugetlb entry; `max` (MaxUsage) does not exist on cgroup v2.
struct HugetlbEntry: Equatable, Sendable {
    var usage: UInt64 = 0
    var max: UInt64 = 0
    var failcnt: UInt64 = 0
}

/// The cgroup v2 subset of runc's events Stats. Fields that runc's fs2
/// manager never fills on cgroup v2 (per-CPU usage, cpuset values, kernel
/// memory, other blkio tables) are encoded as runc does, empty or zero.
/// Intel RDT and network interfaces are not collected: runc encodes them
/// as `{}` and `null` when they are not configured, and so does this.
public struct ContainerStats: Equatable, Sendable {
    var cpuTotal: UInt64 = 0
    var cpuKernel: UInt64 = 0
    var cpuUser: UInt64 = 0
    var throttlingPeriods: UInt64 = 0
    var throttledPeriods: UInt64 = 0
    var throttledTime: UInt64 = 0
    var cpuPSI: PSIStats?

    var memoryCache: UInt64 = 0
    var memoryUsage = MemoryEntry()
    var swapUsage = MemoryEntry()
    var memoryRaw: [String: UInt64] = [:]
    var memoryPSI: PSIStats?

    var pidsCurrent: UInt64 = 0
    var pidsLimit: UInt64 = 0

    var ioServiceBytes: [BlkioEntry] = []
    var ioServiced: [BlkioEntry] = []
    var ioPSI: PSIStats?

    var hugetlb: [String: HugetlbEntry] = [:]
}

/// One line of `events` output, encoded like runc's json.Encoder.
public enum ContainerEvent: Equatable, Sendable {
    case stats(ContainerStats)
    case oom

    public func json(id: String) -> String {
        var object = JSONObject()
        switch self {
        case let .stats(stats):
            object.string("type", "stats")
            object.string("id", id)
            object.raw("data", stats.json)
        case .oom:
            // Event.Data is omitempty and nil for OOM.
            object.string("type", "oom")
            object.string("id", id)
        }
        return object.text
    }
}

extension ContainerStats {
    /// Encodes with runc's JSON names, omitempty/omitzero rules and units.
    var json: String {
        var stats = JSONObject()

        // Cpu: usage and throttling are omitzero, psi is a nil-able pointer.
        var cpu = JSONObject()
        if cpuTotal != 0 || cpuKernel != 0 || cpuUser != 0 {
            var usage = JSONObject()
            usage.uint("total", cpuTotal, omitEmpty: true)
            usage.uint("kernel", cpuKernel)
            usage.uint("user", cpuUser)
            cpu.raw("usage", usage.text)
        }
        if throttlingPeriods != 0 || throttledPeriods != 0 || throttledTime != 0 {
            var throttling = JSONObject()
            throttling.uint("periods", throttlingPeriods, omitEmpty: true)
            throttling.uint("throttledPeriods", throttledPeriods, omitEmpty: true)
            throttling.uint("throttledTime", throttledTime, omitEmpty: true)
            cpu.raw("throttling", throttling.text)
        }
        cpu.psi(cpuPSI)
        stats.raw("cpu", cpu.text)

        // runc's fs2 manager leaves CPUSetStats zero; cpus/mems are omitempty.
        var cpuset = JSONObject()
        for name in [
            "cpu_exclusive", "mem_hardwall", "mem_exclusive", "memory_migrate", "memory_spread_page",
            "memory_spread_slab", "memory_pressure", "sched_load_balance", "sched_relax_domain_level",
        ] {
            cpuset.uint(name, 0)
        }
        stats.raw("cpuset", cpuset.text)

        // Memory: kernel and kernelTCP are always zero on v2, so omitzero
        // drops them.
        var memory = JSONObject()
        memory.uint("cache", memoryCache, omitEmpty: true)
        if !memoryUsage.isZero { memory.raw("usage", memoryUsage.json) }
        if !swapUsage.isZero { memory.raw("swap", swapUsage.json) }
        if !memoryRaw.isEmpty {
            var raw = JSONObject()
            for key in memoryRaw.keys.sorted() { raw.uint(key, memoryRaw[key] ?? 0) }
            memory.raw("raw", raw.text)
        }
        memory.psi(memoryPSI)
        stats.raw("memory", memory.text)

        var pids = JSONObject()
        pids.uint("current", pidsCurrent, omitEmpty: true)
        pids.uint("limit", pidsLimit, omitEmpty: true)
        stats.raw("pids", pids.text)

        var blkio = JSONObject()
        blkio.entries("ioServiceBytesRecursive", ioServiceBytes)
        blkio.entries("ioServicedRecursive", ioServiced)
        blkio.psi(ioPSI)
        stats.raw("blkio", blkio.text)

        // The hugetlb map is not omitempty; Go sorts map keys.
        var hugetlb = JSONObject()
        for size in self.hugetlb.keys.sorted() {
            let entry = self.hugetlb[size] ?? HugetlbEntry()
            var object = JSONObject()
            object.uint("usage", entry.usage, omitEmpty: true)
            object.uint("max", entry.max, omitEmpty: true)
            object.uint("failcnt", entry.failcnt)
            hugetlb.raw(size, object.text)
        }
        stats.raw("hugetlb", hugetlb.text)

        stats.raw("intel_rdt", "{}")
        stats.raw("network_interfaces", "null")
        return stats.text
    }
}

extension MemoryEntry {
    fileprivate var json: String {
        var object = JSONObject()
        object.uint("limit", limit)
        object.uint("usage", usage, omitEmpty: true)
        object.uint("max", max, omitEmpty: true)
        object.uint("failcnt", failcnt)
        return object.text
    }
}

/// A minimal writer for Go-compatible JSON objects.
struct JSONObject {
    private var members: [String] = []

    var text: String { "{" + members.joined(separator: ",") + "}" }

    mutating func raw(_ key: String, _ value: String) {
        members.append(Self.quote(key) + ":" + value)
    }

    mutating func string(_ key: String, _ value: String) { raw(key, Self.quote(value)) }

    mutating func uint(_ key: String, _ value: UInt64, omitEmpty: Bool = false) {
        if omitEmpty, value == 0 { return }
        raw(key, String(value))
    }

    /// PSIStats is a struct, so `some` and `full` are always present.
    mutating func psi(_ stats: PSIStats?) {
        guard let stats else { return }
        func data(_ data: PSIData) -> String {
            var object = JSONObject()
            object.raw("avg10", Self.float(data.avg10))
            object.raw("avg60", Self.float(data.avg60))
            object.raw("avg300", Self.float(data.avg300))
            object.uint("total", data.total)
            return object.text
        }
        var object = JSONObject()
        object.raw("some", data(stats.some))
        object.raw("full", data(stats.full))
        raw("psi", object.text)
    }

    mutating func entries(_ key: String, _ entries: [BlkioEntry]) {
        guard !entries.isEmpty else { return }
        let items = entries.map { entry in
            var object = JSONObject()
            object.uint("major", entry.major, omitEmpty: true)
            object.uint("minor", entry.minor, omitEmpty: true)
            if !entry.op.isEmpty { object.string("op", entry.op) }
            object.uint("value", entry.value, omitEmpty: true)
            return object.text
        }
        raw(key, "[" + items.joined(separator: ",") + "]")
    }

    /// Go encodes float64 in the shortest form, without a trailing ".0".
    /// PSI averages are two-decimal percentages, well inside the range
    /// where Go uses plain decimal notation.
    static func float(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return "\(value)"
    }

    /// Go's encoder escapes quotes, backslashes, control characters and,
    /// with HTML escaping on by default, <, > and &.
    static func quote(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "<", ">", "&", "\u{2028}", "\u{2029}":
                result += "\\u" + hex4(scalar.value)
            default:
                if scalar.value < 0x20 {
                    result += "\\u" + hex4(scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    private static func hex4(_ value: UInt32) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }
}
