import SystemPackage

/// Collects one snapshot through an injected cgroup interface reader.
struct CgroupStatsReader {
    let read: CgroupFileReader
    let hugePageSizes: [String]

    /// runc's fs2 Stats over one cgroup directory. Each controller fills what
    /// it can; as in runc, a missing file (ENOENT) is not an error for memory,
    /// io, cpu and hugetlb, PSI is absent when unavailable, and pids falls back
    /// to counting cgroup.procs. Other errors are collected and fail the call
    /// unless `tolerateErrors` (runc's rootless mode) is set.
    func collect(tolerateErrors: Bool) throws -> ContainerStats {
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
                stats.pidsCurrent = try CgroupFile.uint(current, file: "pids.current")
                let limit = try CgroupFile.uint(try require("pids.max"), file: "pids.max")
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
            for (key, value) in try CgroupFile.keyValues(try require("memory.stat"), file: "memory.stat") {
                stats.memoryRaw[key] = value
            }
            stats.memoryCache = stats.memoryRaw["file"] ?? 0
            let usage = try memory(prefix: "memory", optional: false)
            stats.memoryUsage = usage
            // Without swap accounting, the swap-only values are zero.
            var swap = try memory(prefix: "memory.swap", optional: true)
            swap.usage &+= usage.usage
            if swap.limit != .max { swap.limit &+= usage.limit }
            swap.max = 0
            stats.swapUsage = swap
        }, ignoringMissing: true)

        // io (Linux 4.5+): only the tables runc exports in events.
        record({
            let tables = try CgroupFile.io(try require("io.stat"))
            stats.ioServiceBytes = tables.serviceBytes
            stats.ioServiced = tables.serviced
        }, ignoringMissing: true)

        // cpu.stat exists even without the cpu controller (Linux 4.15+).
        record({
            for (key, value) in try CgroupFile.keyValues(try require("cpu.stat"), file: "cpu.stat") {
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
                return try CgroupFile.pressure(text, file: file)
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
                entry.usage = try CgroupFile.uint(usage ?? "", file: prefix + ".current")
                let events = try CgroupFile.keyValues(try require(prefix + ".events"), file: prefix + ".events")
                entry.failcnt = events.first(where: { $0.0 == "max" })?.1 ?? 0
                stats.hugetlb[size] = entry
            }
        }, ignoringMissing: true)

        if !errors.isEmpty, !tolerateErrors {
            throw RuntimeError("error while statting cgroup v2: [\(errors.joined(separator: " "))]")
        }
        return stats
    }

    /// runc's getMemoryDataV2 for `prefix` ("memory" or "memory.swap"). The
    /// peak is optional (Linux 5.19 / 6.5); a missing swap counter means no
    /// swap accounting and yields zeros.
    private func memory(prefix: String, optional: Bool) throws -> MemoryEntry {
        guard let current = try read(prefix + ".current") else {
            if optional { return MemoryEntry() }
            throw CgroupStatsError.missing(prefix + ".current")
        }
        var entry = MemoryEntry()
        entry.usage = try CgroupFile.uint(current, file: prefix + ".current")
        guard let limit = try read(prefix + ".max") else { throw CgroupStatsError.missing(prefix + ".max") }
        entry.limit = try CgroupFile.uint(limit, file: prefix + ".max")
        if let peak = try read(prefix + ".peak") {
            entry.max = try CgroupFile.uint(peak, file: prefix + ".peak")
        }
        return entry
    }
}

/// Reads a cgroup interface file: nil when it does not exist (ENOENT);
/// other failures throw, with `Errno` when the kernel reported one.
typealias CgroupFileReader = (String) throws -> String?

enum CgroupStatsError: Error, CustomStringConvertible {
    case missing(String)

    var description: String {
        switch self {
        case let .missing(file): "open \(file): no such file or directory"
        }
    }
}
