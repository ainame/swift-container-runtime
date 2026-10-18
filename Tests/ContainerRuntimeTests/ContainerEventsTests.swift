#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SystemPackage
import Testing
@testable import ContainerRuntime

// MARK: - Duration parsing

@Test(arguments: [
    ("5s", Int64(5_000_000_000)),
    ("0", 0),
    ("+2s", 2_000_000_000),
    ("-1.5s", -1_500_000_000),
    ("1m30s", 90_000_000_000),
    ("1.5h", 5_400_000_000_000),
    (".5s", 500_000_000),
    ("1.s", 1_000_000_000),
    ("300ms", 300_000_000),
    ("2us", 2_000),
    ("2\u{00B5}s", 2_000),
    ("2\u{03BC}s", 2_000),
    ("10ns", 10),
    ("1.0000000009s", 1_000_000_000),
    ("0000000000000000000000001s", 1_000_000_000),
    ("9223372036854775807ns", Int64.max),
    ("-9223372036854775808ns", Int64.min),
])
func parsesDurations(text: String, nanoseconds: Int64) throws {
    #expect(try Duration(parsing: text) == .nanoseconds(nanoseconds))
}

@Test(arguments: [
    ("", "expected a number"),
    ("-", "expected a number"),
    ("s", "expected a number"),
    (".s", "expected a number"),
    ("1.2.3s", "expected a number"),
    ("5", "missing unit"),
    ("1s5", "missing unit"),
    ("5x", "unknown unit \"x\""),
    ("5 s", "unknown unit \" s\""),
    ("9223372036854775808ns", "out of range"),
    ("3000000h", "out of range"),
    ("9223372036854775807ns1ns", "out of range"),
    ("100000000000000000000000s", "out of range"),
])
func rejectsMalformedDurations(text: String, reason: String) {
    do {
        let duration = try Duration(parsing: text)
        Issue.record("parsed as \(duration)")
    } catch {
        #expect(error.reason == reason)
    }
}

@Test func describesRefusedDurationsWithTheText() {
    #expect(DurationParseError(text: "5x", reason: "missing unit").description == #"invalid duration "5x": missing unit"#)
}

@Test func skipsMissedTicksInConstantTime() {
    #expect(EventSchedule.next(after: 0, interval: 5) == 5)
    #expect(EventSchedule.next(after: 4, interval: 5) == 5)
    #expect(EventSchedule.next(after: 5, interval: 5) == 10)
    #expect(EventSchedule.next(after: 23, interval: 5) == 25)
    // A 1ns interval far behind the clock lands just after it, without looping.
    #expect(EventSchedule.next(after: 3_600_000_000_000, interval: 1) == 3_600_000_000_001)
    #expect(EventSchedule.next(after: Int64.max - 1, interval: 1) == Int64.max)
    #expect(EventSchedule.next(after: Int64.max, interval: 1) == Int64.max)
    #expect(EventSchedule.next(after: 10, interval: Int64.max) == Int64.max)
    #expect(EventSchedule.next(after: -1, interval: 3) == 3)
}

@Test func convertsElapsedDurations() {
    #expect(EventSchedule.nanoseconds(.milliseconds(1500)) == 1_500_000_000)
    #expect(EventSchedule.nanoseconds(.nanoseconds(7)) == 7)
    #expect(EventSchedule.nanoseconds(.seconds(-1)) == 0)
    #expect(EventSchedule.nanoseconds(.seconds(Int64.max)) == Int64.max)
}

// MARK: - JSON encoding

/// What runc prints for a cgroup with no readable statistics.
private let emptyStatsJSON = #"{"cpu":{},"cpuset":{"cpu_exclusive":0,"mem_hardwall":0,"mem_exclusive":0,"memory_migrate":0,"#
    + #""memory_spread_page":0,"memory_spread_slab":0,"memory_pressure":0,"sched_load_balance":0,"sched_relax_domain_level":0},"#
    + #""memory":{},"pids":{},"blkio":{},"hugetlb":{},"intel_rdt":{},"network_interfaces":null}"#

@Test func encodesEventsWithRuncOmissions() throws {
    #expect(try JSONValue(ContainerEvent.oom.json(id: "box")) == JSONValue(#"{"type":"oom","id":"box"}"#))
    #expect(
        try JSONValue(ContainerEvent.stats(ContainerStats()).json(id: "box"))
            == JSONValue(#"{"type":"stats","id":"box","data":"# + emptyStatsJSON + "}"))
}

@Test func encodesEventLinesDeterministically() throws {
    let line = try ContainerEvent.oom.json(id: "a/<b>")
    #expect(line == #"{"id":"a/<b>","type":"oom"}"#)
    #expect(!line.contains("\n"))
}

/// Parsed JSON, so tests compare values rather than formatting.
private indirect enum JSONValue: Decodable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), unsigned(UInt64), number(Double), bool(Bool), null

    init(_ text: String) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(UInt64.self) { self = .unsigned(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    subscript(_ key: String) -> JSONValue? {
        if case let .object(members) = self { members[key] } else { nil }
    }
}

private func statsJSON(_ stats: ContainerStats) throws -> JSONValue {
    try #require(JSONValue(ContainerEvent.stats(stats).json(id: "box"))["data"])
}

// MARK: - Collection from cgroup v2 files

private struct FakeCgroup {
    var files: [String: String]
    var unsupported: Set<String> = []

    func read(_ file: String) throws -> String? {
        if unsupported.contains(file) { throw Errno.notSupported }
        return files[file]
    }
}

private let populatedCgroup = FakeCgroup(files: [
    "pids.current": "3\n",
    "pids.max": "max\n",
    "memory.stat": "anon 4096\nfile 8192\nkernel 512\n",
    "memory.current": "16384\n",
    "memory.max": "1048576\n",
    "memory.peak": "20480\n",
    "memory.swap.current": "100\n",
    "memory.swap.max": "max\n",
    "memory.events": "low 0\nhigh 0\nmax 2\noom 1\noom_kill 1\n",
    "io.stat": "8:0 rbytes=10 wbytes=20 rios=1 wios=2 dbytes=0 dios=0\n",
    "cpu.stat": "usage_usec 7\nuser_usec 5\nsystem_usec 2\nnr_periods 4\nnr_throttled 1\nthrottled_usec 3\n",
    "cpu.pressure": "some avg10=0.23 avg60=0.00 avg300=1.50 total=99\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=7\n",
    "memory.pressure": "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n",
    "hugetlb.2MB.current": "0\n",
    "hugetlb.2MB.events": "max 4\n",
])

@Test func collectsRuncFieldsAndUnits() throws {
    let cgroup = populatedCgroup
    let stats = try CgroupStatsReader(read: cgroup.read, hugePageSizes: ["2MB"]).collect(tolerateErrors: false)

    // cpu.stat microseconds become nanoseconds; periods stay counts.
    #expect(stats.cpuTotal == 7_000)
    #expect(stats.cpuUser == 5_000)
    #expect(stats.cpuKernel == 2_000)
    #expect(stats.throttlingPeriods == 4)
    #expect(stats.throttledPeriods == 1)
    #expect(stats.throttledTime == 3_000)
    #expect(stats.cpuPSI?.some == PSIData(avg10: 0.23, avg60: 0, avg300: 1.5, total: 99))
    #expect(stats.cpuPSI?.full.total == 7)

    // pids.max "max" is reported as no limit (0).
    #expect(stats.pidsCurrent == 3)
    #expect(stats.pidsLimit == 0)

    // Swap is reported as memory+swap; unlimited swap keeps UInt64.max.
    #expect(stats.memoryCache == 8192)
    #expect(stats.memoryRaw == ["anon": 4096, "file": 8192, "kernel": 512])
    #expect(stats.memoryUsage == MemoryEntry(limit: 1_048_576, usage: 16_384, max: 20_480, failcnt: 0))
    #expect(stats.swapUsage == MemoryEntry(limit: .max, usage: 16_484, max: 0, failcnt: 0))

    #expect(stats.ioServiceBytes == [
        BlkioEntry(major: 8, minor: 0, op: "Read", value: 10), BlkioEntry(major: 8, minor: 0, op: "Write", value: 20),
    ])
    #expect(stats.ioServiced == [
        BlkioEntry(major: 8, minor: 0, op: "Read", value: 1), BlkioEntry(major: 8, minor: 0, op: "Write", value: 2),
    ])
    // io.pressure is missing, so blkio has no psi.
    #expect(stats.ioPSI == nil)

    // Without hugetlb.*.rsvd.current, usage falls back to .current.
    #expect(stats.hugetlb == ["2MB": HugetlbEntry(usage: 0, max: 0, failcnt: 4)])

    let json = try statsJSON(stats)
    #expect(json["cpu"]?["usage"] == (try JSONValue(#"{"total":7000,"kernel":2000,"user":5000}"#)))
    #expect(json["cpu"]?["throttling"] == (try JSONValue(#"{"periods":4,"throttledPeriods":1,"throttledTime":3000}"#)))
    #expect(json["cpu"]?["psi"]?["some"] == (try JSONValue(#"{"avg10":0.23,"avg60":0,"avg300":1.5,"total":99}"#)))
    #expect(json["memory"]?["swap"] == (try JSONValue(#"{"limit":18446744073709551615,"usage":16484,"failcnt":0}"#)))
    #expect(json["pids"] == (try JSONValue(#"{"current":3}"#)))
    #expect(json["hugetlb"] == (try JSONValue(#"{"2MB":{"failcnt":4}}"#)))
}

@Test func addsSwapLimitToMemoryLimitWhenSwapIsLimited() throws {
    var cgroup = populatedCgroup
    cgroup.files["memory.swap.max"] = "1000\n"
    cgroup.files["memory.swap.peak"] = "50\n"
    let stats = try CgroupStatsReader(read: cgroup.read, hugePageSizes: []).collect(tolerateErrors: false)
    #expect(stats.swapUsage == MemoryEntry(limit: 1_049_576, usage: 16_484, max: 0, failcnt: 0))
}

@Test func toleratesMissingControllersAsRuncDoes() throws {
    // Only cgroup.procs and cpu.stat: no pids, memory, io, PSI or hugetlb.
    let cgroup = FakeCgroup(
        files: ["cgroup.procs": "10\n11\n", "cpu.stat": "usage_usec 1\nuser_usec 1\nsystem_usec 0\n"],
        unsupported: ["memory.pressure"]
    )
    let stats = try CgroupStatsReader(read: cgroup.read, hugePageSizes: ["2MB"]).collect(tolerateErrors: false)
    #expect(stats.pidsCurrent == 2)
    #expect(stats.pidsLimit == 0)
    #expect(stats.memoryRaw.isEmpty)
    #expect(stats.memoryUsage == MemoryEntry())
    #expect(stats.cpuPSI == nil && stats.memoryPSI == nil && stats.ioPSI == nil)
    #expect(stats.hugetlb.isEmpty)
    let json = try statsJSON(stats)
    #expect(json["memory"] == (try JSONValue("{}")))
    #expect(json["cpu"] == (try JSONValue(#"{"usage":{"total":1000,"kernel":0,"user":1000}}"#)))
}

@Test func keepsMemoryStatWhenUsageFilesAreMissing() throws {
    let cgroup = FakeCgroup(files: ["pids.current": "1\n", "pids.max": "5\n", "memory.stat": "file 3\n"])
    let stats = try CgroupStatsReader(read: cgroup.read, hugePageSizes: []).collect(tolerateErrors: false)
    #expect(stats.memoryCache == 3)
    #expect(stats.memoryUsage == MemoryEntry())
    #expect(stats.pidsLimit == 5)
}

@Test func reportsMalformedFilesUnlessTolerated() throws {
    var cgroup = populatedCgroup
    cgroup.files["cpu.stat"] = "usage_usec x\n"
    #expect(throws: (any Error).self) {
        try CgroupStatsReader(read: cgroup.read, hugePageSizes: []).collect(tolerateErrors: false)
    }
    let stats = try CgroupStatsReader(read: cgroup.read, hugePageSizes: []).collect(tolerateErrors: true)
    #expect(stats.pidsCurrent == 3)
    #expect(stats.cpuTotal == 0)

    // A missing pids.max beside pids.current is an error in runc too.
    var noLimit = populatedCgroup
    noLimit.files["pids.max"] = nil
    #expect(throws: (any Error).self) {
        try CgroupStatsReader(read: noLimit.read, hugePageSizes: []).collect(tolerateErrors: false)
    }
}

@Test func parsesCgroupValues() throws {
    #expect(try CgroupFile.uint("max\n", file: "f") == .max)
    #expect(try CgroupFile.uint("-1\n", file: "f") == 0)
    #expect(try CgroupFile.uint("42\n", file: "f") == 42)
    #expect(throws: (any Error).self) { try CgroupFile.uint("x", file: "f") }
}

@Test func namesHugePageSizesLikeRunc() {
    #expect(CgroupFile.hugePageSize(directoryEntry: "hugepages-2048kB") == "2MB")
    #expect(CgroupFile.hugePageSize(directoryEntry: "hugepages-1048576kB") == "1GB")
    #expect(CgroupFile.hugePageSize(directoryEntry: "hugepages-64kB") == "64KB")
    #expect(CgroupFile.hugePageSize(directoryEntry: "hugepages-16777216kB") == "16GB")
    #expect(CgroupFile.hugePageSize(directoryEntry: "other") == nil)
}
