#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

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

/// One line of `events` output, with runc's field names and omitted fields.
public enum ContainerEvent: Equatable, Sendable {
    case stats(ContainerStats)
    case oom

    public func json(id: String) throws -> String {
        let line: EventLine
        switch self {
        case let .stats(stats): line = EventLine(type: "stats", id: id, data: stats)
        // The event's data is omitted for OOM.
        case .oom: line = EventLine(type: "oom", id: id, data: nil)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(line), as: UTF8.self)
    }

    private struct EventLine: Encodable {
        let type: String
        let id: String
        let data: ContainerStats?
    }
}

/// The JSON shape of runc's events Stats. Optional fields are omitted when
/// nil, mirroring runc's omitempty fields, so consumers see the same keys.
extension ContainerStats: Encodable {
    private enum CodingKeys: String, CodingKey {
        case cpu, cpuset, memory, pids, blkio, hugetlb
        case intelRDT = "intel_rdt", networkInterfaces = "network_interfaces"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(CPU(self), forKey: .cpu)
        try container.encode(CPUSet(), forKey: .cpuset)
        try container.encode(Memory(self), forKey: .memory)
        try container.encode(Pids(current: pidsCurrent.nonZero, limit: pidsLimit.nonZero), forKey: .pids)
        try container.encode(
            Blkio(
                ioServiceBytesRecursive: ioServiceBytes.isEmpty ? nil : ioServiceBytes.map(BlkioJSON.init),
                ioServicedRecursive: ioServiced.isEmpty ? nil : ioServiced.map(BlkioJSON.init),
                psi: ioPSI.map(PSIJSON.init)),
            forKey: .blkio)
        try container.encode(hugetlb.mapValues(HugetlbJSON.init), forKey: .hugetlb)
        // Not collected: runc reports Intel RDT as {} and network interfaces as null.
        try container.encode([String: UInt64](), forKey: .intelRDT)
        try container.encodeNil(forKey: .networkInterfaces)
    }

    private struct CPU: Encodable {
        struct Usage: Encodable { let total: UInt64?, kernel: UInt64, user: UInt64 }
        struct Throttling: Encodable { let periods: UInt64?, throttledPeriods: UInt64?, throttledTime: UInt64? }
        let usage: Usage?
        let throttling: Throttling?
        let psi: PSIJSON?

        init(_ stats: ContainerStats) {
            usage = stats.cpuTotal == 0 && stats.cpuKernel == 0 && stats.cpuUser == 0
                ? nil : Usage(total: stats.cpuTotal.nonZero, kernel: stats.cpuKernel, user: stats.cpuUser)
            throttling = stats.throttlingPeriods == 0 && stats.throttledPeriods == 0 && stats.throttledTime == 0
                ? nil
                : Throttling(
                    periods: stats.throttlingPeriods.nonZero, throttledPeriods: stats.throttledPeriods.nonZero,
                    throttledTime: stats.throttledTime.nonZero)
            psi = stats.cpuPSI.map(PSIJSON.init)
        }
    }

    /// runc's cgroup v2 manager leaves every cpuset statistic zero.
    private struct CPUSet: Encodable {
        let cpu_exclusive = 0, mem_hardwall = 0, mem_exclusive = 0, memory_migrate = 0
        let memory_spread_page = 0, memory_spread_slab = 0, memory_pressure = 0
        let sched_load_balance = 0, sched_relax_domain_level = 0
    }

    /// Kernel memory is always zero on cgroup v2, so it is never present.
    private struct Memory: Encodable {
        let cache: UInt64?
        let usage: MemoryJSON?
        let swap: MemoryJSON?
        let raw: [String: UInt64]?
        let psi: PSIJSON?

        init(_ stats: ContainerStats) {
            cache = stats.memoryCache.nonZero
            usage = stats.memoryUsage.isZero ? nil : MemoryJSON(stats.memoryUsage)
            swap = stats.swapUsage.isZero ? nil : MemoryJSON(stats.swapUsage)
            raw = stats.memoryRaw.isEmpty ? nil : stats.memoryRaw
            psi = stats.memoryPSI.map(PSIJSON.init)
        }
    }

    private struct MemoryJSON: Encodable {
        let limit: UInt64, usage: UInt64?, max: UInt64?, failcnt: UInt64
        init(_ entry: MemoryEntry) {
            limit = entry.limit
            usage = entry.usage.nonZero
            max = entry.max.nonZero
            failcnt = entry.failcnt
        }
    }

    private struct Pids: Encodable { let current: UInt64?, limit: UInt64? }

    private struct Blkio: Encodable {
        let ioServiceBytesRecursive: [BlkioJSON]?
        let ioServicedRecursive: [BlkioJSON]?
        let psi: PSIJSON?
    }

    private struct BlkioJSON: Encodable {
        let major: UInt64?, minor: UInt64?, op: String?, value: UInt64?
        init(_ entry: BlkioEntry) {
            major = entry.major.nonZero
            minor = entry.minor.nonZero
            op = entry.op.isEmpty ? nil : entry.op
            value = entry.value.nonZero
        }
    }

    private struct HugetlbJSON: Encodable {
        let usage: UInt64?, max: UInt64?, failcnt: UInt64
        init(_ entry: HugetlbEntry) {
            usage = entry.usage.nonZero
            max = entry.max.nonZero
            failcnt = entry.failcnt
        }
    }

    /// Both `some` and `full` are always present once PSI is reported.
    private struct PSIJSON: Encodable {
        let some: PSIData, full: PSIData
        init(_ stats: PSIStats) {
            some = stats.some
            full = stats.full
        }
    }
}

extension PSIData: Encodable {}

private extension UInt64 {
    /// Nil for zero, for fields runc omits when empty.
    var nonZero: UInt64? { self == 0 ? nil : self }
}
