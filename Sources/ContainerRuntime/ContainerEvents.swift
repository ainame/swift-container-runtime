import SystemPackage

/// Go's time.ParseDuration, which runc uses for `events --interval`.
/// Returns nanoseconds; the error text matches Go's.
public func parseGoDuration(_ text: String) throws -> Int64 {
    let invalid = RuntimeError("time: invalid duration \(goQuote(text))")
    var bytes = Substring(text).utf8[...]
    var negative = false
    if let first = bytes.first, first == UInt8(ascii: "-") || first == UInt8(ascii: "+") {
        negative = first == UInt8(ascii: "-")
        bytes = bytes.dropFirst()
    }
    if bytes.elementsEqual("0".utf8) { return 0 }
    guard !bytes.isEmpty else { throw invalid }

    let limit: UInt64 = 1 << 63
    let units: [String: UInt64] = [
        "ns": 1, "us": 1_000, "\u{00B5}s": 1_000, "\u{03BC}s": 1_000,
        "ms": 1_000_000, "s": 1_000_000_000, "m": 60_000_000_000, "h": 3_600_000_000_000,
    ]
    func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }
    let dot = UInt8(ascii: ".")

    var total: UInt64 = 0
    while let first = bytes.first {
        guard first == dot || isDigit(first) else { throw invalid }

        // The integer part; overflow is an error, as in Go's leadingInt.
        var value: UInt64 = 0
        var sawInteger = false
        while let byte = bytes.first, isDigit(byte) {
            guard value <= limit / 10 else { throw invalid }
            value = value * 10 + UInt64(byte - UInt8(ascii: "0"))
            guard value <= limit else { throw invalid }
            bytes = bytes.dropFirst()
            sawInteger = true
        }

        // The fraction stops accumulating once it would overflow, as in
        // Go's leadingFraction.
        var fraction: UInt64 = 0
        var scale = 1.0
        var sawFraction = false
        if bytes.first == dot {
            bytes = bytes.dropFirst()
            var overflowed = false
            while let byte = bytes.first, isDigit(byte) {
                bytes = bytes.dropFirst()
                sawFraction = true
                if overflowed { continue }
                guard fraction <= (limit - 1) / 10 else { overflowed = true; continue }
                let next = fraction * 10 + UInt64(byte - UInt8(ascii: "0"))
                guard next <= limit else { overflowed = true; continue }
                fraction = next
                scale *= 10
            }
        }
        guard sawInteger || sawFraction else { throw invalid }

        // The unit runs to the next number.
        let unitBytes = bytes.prefix { $0 != dot && !isDigit($0) }
        bytes = bytes.dropFirst(unitBytes.count)
        let unitName = String(decoding: unitBytes, as: UTF8.self)
        guard !unitBytes.isEmpty else { throw RuntimeError("time: missing unit in duration \(goQuote(text))") }
        guard let unit = units[unitName] else {
            throw RuntimeError("time: unknown unit \(goQuote(unitName)) in duration \(goQuote(text))")
        }

        guard value <= limit / unit else { throw invalid }
        value *= unit
        // value is at most 2^63 and the fraction adds less than one unit,
        // so this sum cannot wrap.
        if fraction > 0 {
            value += UInt64(Double(fraction) * (Double(unit) / scale))
            guard value <= limit else { throw invalid }
        }
        // Go's uint64 sum wraps here, so "-9223372036854775808ns9223372036854775808ns"
        // parses as 0 there; a sum beyond 2^63 is rejected instead of wrapping.
        guard value <= limit - total else { throw invalid }
        total += value
    }
    if negative { return total == limit ? Int64.min : -Int64(total) }
    guard total <= UInt64(Int64.max) else { throw invalid }
    return Int64(total)
}

/// The offset of the first stats tick after `elapsed`, for ticks every
/// `interval` nanoseconds from the start of a stream. Missed ticks are
/// skipped in constant time, as Go's time.Ticker drops ticks for a slow
/// reader; an offset beyond Int64 saturates.
func nextTickOffset(elapsed: Int64, interval: Int64) -> Int64 {
    precondition(interval > 0)
    let (ticks, countOverflow) = (max(elapsed, 0) / interval).addingReportingOverflow(1)
    let (offset, overflow) = ticks.multipliedReportingOverflow(by: interval)
    return countOverflow || overflow ? .max : offset
}

/// A non-negative duration in whole nanoseconds, saturating at Int64.max.
func elapsedNanoseconds(_ duration: Duration) -> Int64 {
    let (seconds, attoseconds) = duration.components
    guard seconds >= 0 else { return 0 }
    let (whole, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    guard !overflow else { return .max }
    let (total, sumOverflow) = whole.addingReportingOverflow(attoseconds / 1_000_000_000)
    return sumOverflow ? .max : total
}

/// Go's %q for the ASCII-safe texts this runtime reports.
private func goQuote(_ text: String) -> String {
    var result = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": result += "\\\""
        case "\\": result += "\\\\"
        case "\n": result += "\\n"
        case "\t": result += "\\t"
        default: result.unicodeScalars.append(scalar)
        }
    }
    return result + "\""
}

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

/// Reads a cgroup interface file: nil when it does not exist (ENOENT);
/// other failures throw, with `Errno` when the kernel reported one.
typealias CgroupFileReader = (String) throws -> String?

/// runc's fs2 Stats over one cgroup directory. Each controller fills what
/// it can; as in runc, a missing file (ENOENT) is not an error for memory,
/// io, cpu and hugetlb, PSI is absent when unavailable, and pids falls back
/// to counting cgroup.procs. Other errors are collected and fail the call
/// unless `tolerateErrors` (runc's rootless mode) is set.
func collectCgroupStats(
    read: CgroupFileReader, hugePageSizes: [String], tolerateErrors: Bool
) throws -> ContainerStats {
    var stats = ContainerStats()
    var errors: [String] = []
    func record(_ body: () throws -> Void, ignoringMissing: Bool) {
        do {
            try body()
        } catch CgroupStatsError.missing(_) where ignoringMissing {
            // runc skips a controller whose files do not exist.
        } catch {
            errors.append("\(error)")
        }
    }
    /// Like `read`, but a missing file is an error that the caller may skip.
    func require(_ file: String) throws -> String {
        guard let text = try read(file) else { throw CgroupStatsError.missing(file) }
        return text
    }

    // pids (Linux 4.5+); without the controller, count member processes.
    record({
        if let current = try read("pids.current") {
            stats.pidsCurrent = try parseCgroupUint(current, file: "pids.current")
            let limit = try parseCgroupUint(try require("pids.max"), file: "pids.max")
            stats.pidsLimit = limit == .max ? 0 : limit
        } else {
            let procs: String
            do {
                procs = try require("cgroup.procs")
            } catch let error as Errno where error == .notSupported {
                procs = try require("cgroup.threads")
            }
            stats.pidsCurrent = UInt64(procs.utf8.count(where: { $0 == UInt8(ascii: "\n") }))
            stats.pidsLimit = 0
        }
    }, ignoringMissing: false)

    // memory (Linux 4.5+). Values read before a failure are kept, as in runc.
    record({
        for (key, value) in try parseKeyValueLines(try require("memory.stat"), file: "memory.stat") {
            stats.memoryRaw[key] = value
        }
        stats.memoryCache = stats.memoryRaw["file"] ?? 0
        let usage = try memoryData(read: read, prefix: "memory", optional: false)
        stats.memoryUsage = usage
        // Without swap accounting, the swap-only values are zero.
        var swap = try memoryData(read: read, prefix: "memory.swap", optional: true)
        swap.usage &+= usage.usage
        if swap.limit != .max { swap.limit &+= usage.limit }
        swap.max = 0
        stats.swapUsage = swap
    }, ignoringMissing: true)

    // io (Linux 4.5+): only the tables runc exports in events.
    record({
        let tables = try parseIOStat(try require("io.stat"))
        stats.ioServiceBytes = tables.serviceBytes
        stats.ioServiced = tables.serviced
    }, ignoringMissing: true)

    // cpu.stat exists even without the cpu controller (Linux 4.15+).
    record({
        for (key, value) in try parseKeyValueLines(try require("cpu.stat"), file: "cpu.stat") {
            switch key {
            case "usage_usec": stats.cpuTotal = value &* 1000
            case "user_usec": stats.cpuUser = value &* 1000
            case "system_usec": stats.cpuKernel = value &* 1000
            case "nr_periods": stats.throttlingPeriods = value
            case "nr_throttled": stats.throttledPeriods = value
            case "throttled_usec": stats.throttledTime = value &* 1000
            default: break
            }
        }
    }, ignoringMissing: true)

    // PSI (Linux 4.20+): missing, disabled or unsupported means absent.
    func pressure(_ file: String) -> PSIStats? {
        do {
            guard let text = try read(file) else { return nil }
            return try parsePSI(text, file: file)
        } catch let error as Errno where error == .notSupported {
            return nil
        } catch {
            errors.append("\(error)")
            return nil
        }
    }
    stats.cpuPSI = pressure("cpu.pressure")
    stats.memoryPSI = pressure("memory.pressure")
    stats.ioPSI = pressure("io.pressure")

    // hugetlb (Linux 5.6+); .rsvd.current replaced .current in Linux 5.7.
    record({
        var reserved = true
        for size in hugePageSizes {
            let prefix = "hugetlb." + size
            var usage: String?
            if reserved { usage = try read(prefix + ".rsvd.current") }
            if usage == nil {
                reserved = false
                usage = try require(prefix + ".current")
            }
            var entry = HugetlbEntry()
            entry.usage = try parseCgroupUint(usage ?? "", file: prefix + ".current")
            let events = try parseKeyValueLines(try require(prefix + ".events"), file: prefix + ".events")
            entry.failcnt = events.first(where: { $0.0 == "max" })?.1 ?? 0
            stats.hugetlb[size] = entry
        }
    }, ignoringMissing: true)

    if !errors.isEmpty, !tolerateErrors {
        throw RuntimeError("error while statting cgroup v2: [\(errors.joined(separator: " "))]")
    }
    return stats
}

enum CgroupStatsError: Error, CustomStringConvertible {
    case missing(String)

    var description: String {
        switch self {
        case let .missing(file): "open \(file): no such file or directory"
        }
    }
}

/// runc's getMemoryDataV2 for `prefix` ("memory" or "memory.swap"). The
/// peak is optional (Linux 5.19 / 6.5); a missing swap counter means no
/// swap accounting and yields zeros.
private func memoryData(read: CgroupFileReader, prefix: String, optional: Bool) throws -> MemoryEntry {
    guard let current = try read(prefix + ".current") else {
        if optional { return MemoryEntry() }
        throw CgroupStatsError.missing(prefix + ".current")
    }
    var entry = MemoryEntry()
    entry.usage = try parseCgroupUint(current, file: prefix + ".current")
    guard let limit = try read(prefix + ".max") else { throw CgroupStatsError.missing(prefix + ".max") }
    entry.limit = try parseCgroupUint(limit, file: prefix + ".max")
    if let peak = try read(prefix + ".peak") {
        entry.max = try parseCgroupUint(peak, file: prefix + ".peak")
    }
    return entry
}

/// runc's GetCgroupParamUint: "max" is UInt64.max, a negative value is 0.
func parseCgroupUint(_ text: String, file: String) throws -> UInt64 {
    let value = text.trimmingWhitespace
    if value == "max" { return .max }
    if let parsed = UInt64(value) { return parsed }
    if let signed = Int64(value), signed < 0 { return 0 }
    throw RuntimeError("unable to parse \(file) value \(goQuote(value))")
}

/// "key value" lines (cpu.stat, memory.stat, *.events), in file order.
func parseKeyValueLines(_ text: String, file: String) throws -> [(String, UInt64)] {
    try text.split(separator: "\n").map { line in
        let fields = line.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 2, let value = UInt64(fields[1]) else {
            throw RuntimeError("unable to parse \(file) line \(goQuote(String(line)))")
        }
        return (String(fields[0]), value)
    }
}

/// io.stat: "MAJ:MIN rbytes=N wbytes=N rios=N wios=N ...". Byte and
/// operation counts become runc's Read/Write serviced tables; other keys
/// (dbytes, cost.*) are not part of runc's events output.
func parseIOStat(_ text: String) throws -> (serviceBytes: [BlkioEntry], serviced: [BlkioEntry]) {
    var serviceBytes: [BlkioEntry] = []
    var serviced: [BlkioEntry] = []
    for line in text.split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 2 else { continue }
        let device = fields[0].split(separator: ":", omittingEmptySubsequences: false)
        guard device.count == 2 else { continue }
        guard let major = UInt64(device[0]), let minor = UInt64(device[1]) else {
            throw RuntimeError("unable to parse io.stat device \(goQuote(String(fields[0])))")
        }
        for item in fields.dropFirst() {
            let pair = item.split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let target: (op: String, bytes: Bool)
            switch pair[0] {
            case "rbytes": target = ("Read", true)
            case "wbytes": target = ("Write", true)
            case "rios": target = ("Read", false)
            case "wios": target = ("Write", false)
            default: continue
            }
            guard let value = UInt64(pair[1]) else {
                throw RuntimeError("unable to parse io.stat value \(goQuote(String(item)))")
            }
            let entry = BlkioEntry(major: major, minor: minor, op: target.op, value: value)
            if target.bytes { serviceBytes.append(entry) } else { serviced.append(entry) }
        }
    }
    return (serviceBytes, serviced)
}

/// *.pressure: "some avg10=0.00 avg60=0.00 avg300=0.00 total=0" and an
/// optional "full" line (absent for cpu before Linux 5.13).
func parsePSI(_ text: String, file: String) throws -> PSIStats {
    var stats = PSIStats()
    for line in text.split(separator: "\n") {
        let fields = line.split(separator: " ")
        guard let kind = fields.first, kind == "some" || kind == "full" else { continue }
        var data = PSIData()
        for field in fields.dropFirst() {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw RuntimeError("\(file): invalid psi data: \(goQuote(String(field)))") }
            switch pair[0] {
            case "avg10", "avg60", "avg300":
                guard let value = Double(pair[1]) else {
                    throw RuntimeError("\(file): invalid \(pair[0]) PSI value: \(goQuote(String(pair[1])))")
                }
                if pair[0] == "avg10" { data.avg10 = value } else if pair[0] == "avg60" { data.avg60 = value } else { data.avg300 = value }
            case "total":
                guard let value = UInt64(pair[1]) else {
                    throw RuntimeError("\(file): invalid total PSI value: \(goQuote(String(pair[1])))")
                }
                data.total = value
            default:
                break
            }
        }
        if kind == "some" { stats.some = data } else { stats.full = data }
    }
    return stats
}

/// runc's HugePageSizes naming: "hugepages-2048kB" becomes "2MB", using
/// Go's %g with binary (1024) steps and B/KB/MB/GB/TB/PB suffixes.
func hugePageSizeName(directoryEntry: String) -> String? {
    guard directoryEntry.hasPrefix("hugepages-"), directoryEntry.hasSuffix("kB"),
          let kilobytes = UInt64(directoryEntry.dropFirst("hugepages-".count).dropLast(2)) else { return nil }
    var size = Double(kilobytes) * 1024
    let suffixes = ["B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"]
    var index = 0
    while size >= 1024, index < suffixes.count - 1 {
        size /= 1024
        index += 1
    }
    return JSONObject.float(size) + suffixes[index]
}

extension String {
    fileprivate var trimmingWhitespace: String {
        String(drop(while: { $0.isWhitespace }).reversed().drop(while: { $0.isWhitespace }).reversed())
    }
}
