import SystemPackage
import Testing
@testable import ContainerRuntime

private let box = try! ContainerID("box")

private func plan(linuxFields: String) throws -> OCIRunPlan {
    let json = """
    {"ociVersion": "1.2.0", "root": {"path": "rootfs"},
     "process": {"args": ["/bin/sh"], "cwd": "/"},
     "linux": {"namespaces": [{"type": "mount"}]\(linuxFields)}}
    """
    let configuration = try OCIConfiguration.decode(Array(json.utf8))
    return try OCIRunPlan(configuration, bundle: FilePath("/bundle"), rootfs: FilePath("/bundle/rootfs"))
}

private func resources(_ json: String) throws -> CgroupResources {
    try plan(linuxFields: #", "resources": "# + json).cgroup.resources
}

private func rejection(_ linuxFields: String) -> String? {
    do {
        _ = try plan(linuxFields: linuxFields)
        return nil
    } catch {
        return "\(error)"
    }
}

// MARK: Paths

@Test(arguments: [
    // Absent and empty use the container ID below the runtime prefix.
    ("", ["swift-container-runtime", "box"]),
    (#", "cgroupsPath": """#, ["swift-container-runtime", "box"]),
    (#", "cgroupsPath": null"#, ["swift-container-runtime", "box"]),
    // Relative paths nest below the runtime prefix, absolute ones below the mount root.
    (#", "cgroupsPath": "pod/ctr""#, ["swift-container-runtime", "pod", "ctr"]),
    (#", "cgroupsPath": "/test/ctr""#, ["test", "ctr"]),
    (#", "cgroupsPath": "//test//ctr/""#, ["test", "ctr"]),
])
func resolvesCgroupPaths(_ fields: String, _ components: [String]) throws {
    #expect(try plan(linuxFields: fields).cgroup.components(for: box) == components)
}

@Test(arguments: [
    (#", "cgroupsPath": "/""#, "not the root itself"),
    (#", "cgroupsPath": "///""#, "not the root itself"),
    (#", "cgroupsPath": "/a/../b""#, ". or .. components"),
    (#", "cgroupsPath": "../escape""#, ". or .. components"),
    (#", "cgroupsPath": "./x""#, ". or .. components"),
    (#", "cgroupsPath": "a\nb""#, "newline"),
    (#", "cgroupsPath": "a\u0000b""#, "NUL"),
    (#", "cgroupsPath": 7"#, "linux.cgroupsPath"),
])
func rejectsUnsafeCgroupPaths(_ fields: String, _ reason: String) {
    let message = rejection(fields)
    #expect(message?.contains(reason) == true, "\(message ?? "accepted")")
}

@Test func boundsCgroupPathLength() {
    let long = String(repeating: "a", count: 256)
    #expect(rejection(#", "cgroupsPath": "/"# + long + #"""#)?.contains("255 bytes") == true)
    let deep = (0..<65).map { _ in "a" }.joined(separator: "/")
    #expect(rejection(#", "cgroupsPath": "/"# + deep + #"""#)?.contains("64 components") == true)
}

// MARK: Resources

@Test func absentOrEmptyResourcesWriteNothing() throws {
    #expect(try plan(linuxFields: "").cgroup.resources == .none)
    for json in ["{}", "null", #"{"memory": {}, "pids": null}"#, #"{"memory": {"limit": 0, "reservation": 0, "swap": 0}}"#] {
        let converted = try resources(json)
        #expect(converted == .none, "\(json)")
        #expect(converted.writes.isEmpty)
        #expect(converted.requiredControllers.isEmpty)
    }
}

@Test func pidsFollowRunc() throws {
    // Positive as is, 0 remapped to 1 as systemd's TasksMax needs, any negative is max.
    #expect(try resources(#"{"pids": {"limit": 32}}"#).pidsMax == .number(32))
    #expect(try resources(#"{"pids": {"limit": 0}}"#).pidsMax == .number(1))
    #expect(try resources(#"{"pids": {"limit": -1}}"#).pidsMax == .max)
    #expect(try resources(#"{"pids": {"limit": -9}}"#).pidsMax == .max)
    // An absent limit (optional since runtime-spec 1.2.1) keeps the current value.
    #expect(try resources(#"{"pids": {}}"#).pidsMax == nil)
    let converted = try resources(#"{"pids": {"limit": 9223372036854775807}}"#)
    #expect(converted.writes == [CgroupWrite(file: "pids.max", value: .number(UInt64(Int64.max)), ignoreMissing: false)])
    #expect(converted.requiredControllers == ["pids"])
}

@Test(arguments: [
    // limit, reservation, swap -> memory.max, memory.low, memory.swap.max
    (Int64(33_554_432), Int64(0), Int64(0), CgroupValue.number(33_554_432), CgroupValue?.none, CgroupValue?.none),
    (33_554_432, 16_777_216, 67_108_864, .number(33_554_432), .number(16_777_216), .number(33_554_432)),
    // memory+swap equal to memory disables swap with "0".
    (33_554_432, 0, 33_554_432, .number(33_554_432), nil, .number(0)),
    // -1 is max; unlimited memory without swap also makes swap unlimited.
    (-1, -1, 0, .max, .max, .max),
    (-1, 0, -1, .max, nil, .max),
    (-1, 0, 1_048_576, .max, nil, .number(1_048_576)),
    (33_554_432, 0, -1, .number(33_554_432), nil, .max),
    // A non-page-multiple value is passed through; the kernel rounds it.
    (33_554_433, 0, 0, .number(33_554_433), nil, nil),
] as [(Int64, Int64, Int64, CgroupValue, CgroupValue?, CgroupValue?)])
func memoryFollowsRunc(_ limit: Int64, _ reservation: Int64, _ swap: Int64, _ max: CgroupValue, _ low: CgroupValue?, _ swapMax: CgroupValue?) throws {
    let converted = try resources(#"{"memory": {"limit": \#(limit), "reservation": \#(reservation), "swap": \#(swap)}}"#)
    #expect(converted.memoryMax == max)
    #expect(converted.memoryLow == low)
    #expect(converted.swapMax == swapMax)
    #expect(converted.requiredControllers == ["memory"])
}

@Test func reservationAloneNeedsOnlyMemoryLow() throws {
    let converted = try resources(#"{"memory": {"reservation": 4096}}"#)
    #expect(converted.writes == [CgroupWrite(file: "memory.low", value: .number(4096), ignoreMissing: false)])
}

@Test func ignorableSwapAloneMakesMemoryOptional() throws {
    // runc succeeds for swap -1 alone even without the memory controller.
    let converted = try resources(#"{"memory": {"swap": -1}}"#)
    #expect(converted.writes == [CgroupWrite(file: "memory.swap.max", value: .max, ignoreMissing: true)])
    #expect(converted.requiredControllers.isEmpty)
    #expect(converted.optionalControllers == ["memory"])
    #expect(converted.needsDomainController)
    // A finite swap limit needs memory.swap.max, so memory is required.
    let finite = try resources(#"{"memory": {"limit": 8192, "swap": 16384}}"#)
    #expect(finite.requiredControllers == ["memory"])
    #expect(finite.optionalControllers.isEmpty)
    // pids alone needs no domain controller, so a threaded subtree can host it.
    let pids = try resources(#"{"pids": {"limit": 16}}"#)
    #expect(!pids.needsDomainController)
    #expect(pids.optionalControllers.isEmpty)
}

@Test func writesInRuncOrder() throws {
    let converted = try resources(#"{"memory": {"limit": 8192, "reservation": 4096, "swap": -1}, "pids": {"limit": 5}}"#)
    #expect(converted.writes.map(\.file) == ["pids.max", "memory.swap.max", "memory.max", "memory.low"])
    // A missing memory.swap.max (no swap accounting) is ignored only for max or 0.
    #expect(converted.writes.map(\.ignoreMissing) == [false, true, false, false])
    #expect(try resources(#"{"memory": {"limit": 8192, "swap": 16384}}"#).writes.first?.ignoreMissing == false)
    #expect(try resources(#"{"memory": {"limit": 8192, "swap": 8192}}"#).writes.first?.ignoreMissing == true)
    #expect(converted.requiredControllers == ["memory", "pids"])
    #expect(converted.writes.map(\.value.description) == ["5", "max", "8192", "4096"])
}

@Test(arguments: [
    (#"{"memory": {"swap": 1048576}}"#, "unable to set swap limit without memory limit"),
    (#"{"memory": {"limit": 0, "swap": 1048576}}"#, "unable to set swap limit without memory limit"),
    (#"{"memory": {"limit": 2097152, "swap": 1048576}}"#, "memory+swap limit should be >= memory limit"),
    (#"{"memory": {"limit": -2}}"#, "memory.limit must be -1 (unlimited), 0 (unset), or a positive byte count"),
    (#"{"memory": {"reservation": -2}}"#, "memory.reservation must be"),
    (#"{"memory": {"limit": 1048576, "swap": -2}}"#, "memory.swap must be"),
    (#"{"memory": {"limit": 9223372036854775808}}"#, "invalid value at linux.resources.memory.limit"),
    (#"{"memory": {"limit": 1.5}}"#, "linux.resources.memory.limit"),
    (#"{"memory": {"limit": "1g"}}"#, "linux.resources.memory.limit"),
    (#"{"pids": {"limit": -9223372036854775809}}"#, "invalid value at linux.resources.pids.limit"),
    // Unimplemented controls are rejected, never silently accepted.
    (#"{"cpu": {"realtimeRuntime": 950000}}"#, "unsupported field(s): linux.resources.cpu.realtimeRuntime"),
    (#"{"cpu": {"realtimePeriod": 1000000}}"#, "unsupported field(s): linux.resources.cpu.realtimePeriod"),
    (#"{"cpu": {"weight": 100}}"#, "unsupported field(s): linux.resources.cpu.weight"),
    (#"{"devices": [{"allow": false, "access": "rwm"}]}"#, "linux.resources.devices"),
    (#"{"blockIO": {}}"#, "linux.resources.blockIO"),
    (#"{"hugepageLimits": []}"#, "linux.resources.hugepageLimits"),
    (#"{"unified": {}}"#, "linux.resources.unified"),
    (#"{"memory": {"swappiness": 0}}"#, "linux.resources.memory.swappiness"),
    (#"{"memory": {"disableOOMKiller": true}}"#, "linux.resources.memory.disableOOMKiller"),
    (#"{"memory": {"kernel": 1}}"#, "linux.resources.memory.kernel"),
    (#"{"pids": {"limit": 1, "max": 2}}"#, "linux.resources.pids.max"),
])
func rejectsInvalidAndUnsupportedResources(_ json: String, _ reason: String) {
    let message = rejection(#", "resources": "# + json)
    #expect(message?.contains(reason) == true, "\(message ?? "accepted")")
}

// MARK: Cpusets

@Test(arguments: [#"{}"#, #"{"cpus": "", "mems": ""}"#, #"{"cpus": null, "mems": null}"#])
func emptyCpusetLeavesExistingValues(_ cpu: String) throws {
    let converted = try resources(#"{"cpu": "# + cpu + "}")
    #expect(converted == .none)
}

@Test func cpusetWritesFollowCpuAndDoNotRequireCpuController() throws {
    let cpuset = try resources(#"{"cpu": {"cpus": "0-2,5", "mems": "0"}}"#)
    #expect(cpuset.writes.map { "\($0.file)=\($0.value)" } == ["cpuset.cpus=0-2,5", "cpuset.mems=0"])
    #expect(cpuset.requiredControllers == ["cpuset"])
    #expect(!cpuset.needsDomainController)
    let combined = try resources(#"{"cpu": {"quota": 20000, "cpus": "1", "mems": "0"}, "pids": {"limit": 5}}"#)
    #expect(combined.writes.map(\.file) == ["pids.max", "cpu.max", "cpuset.cpus", "cpuset.mems"])
    #expect(combined.requiredControllers == ["pids", "cpu", "cpuset"])
    // Bad list syntax belongs to the kernel, as in runc's setCpuset.
    #expect(try resources(#"{"cpu": {"cpus": "not-a-list"}}"#).writes.first?.value == .list("not-a-list"))
}

// MARK: CPU

@Test(arguments: [
    // Unset, the clamped ends, and runc's quadratic through 2, 1024 and 262144.
    (UInt64(0), UInt64(0)), (1, 1), (2, 1), (3, 2), (4, 2), (512, 59), (1024, 100), (2048, 174),
    (262_143, 10_000), (262_144, 10_000), (UInt64.max, 10_000),
] as [(UInt64, UInt64)])
func cpuSharesConvertAsRunc(_ shares: UInt64, _ weight: UInt64) {
    #expect(CgroupPlan.cpuWeight(shares: shares) == weight)
}

@Test func cpuWeightIsMonotonicAndBounded() {
    var previous: UInt64 = 1
    var violations: [UInt64] = []
    for shares in stride(from: UInt64(2), through: 262_144, by: 7) {
        let weight = CgroupPlan.cpuWeight(shares: shares)
        if weight < previous || weight > 10_000 { violations.append(shares) }
        previous = weight
    }
    #expect(violations.isEmpty, "shares \(violations.prefix(10))")
}

@Test(arguments: [
    // Absent, empty, and zero values write nothing and need no controller.
    #"{"cpu": null}"#,
    #"{"cpu": {}}"#,
    #"{"cpu": {"shares": null, "quota": null, "period": null, "burst": null, "idle": null}}"#,
    #"{"cpu": {"shares": 0, "quota": 0, "period": 0}}"#,
])
func unsetCpuWritesNothing(_ json: String) throws {
    let converted = try resources(json)
    #expect(converted == .none)
    #expect(converted.cpu == .none && !converted.cpu.isSet)
    #expect(converted.writes.isEmpty)
    #expect(converted.requiredControllers.isEmpty)
    #expect(!converted.needsDomainController)
}

@Test(arguments: [
    // cpu JSON -> file=value writes in setCPU order.
    (#"{"shares": 1024}"#, ["cpu.weight=100"]),
    (#"{"shares": 2}"#, ["cpu.weight=1"]),
    (#"{"shares": 18446744073709551615}"#, ["cpu.weight=10000"]),
    // A quota alone uses the default period; a period alone is unlimited.
    (#"{"quota": 50000}"#, ["cpu.max=50000 100000"]),
    (#"{"period": 50000}"#, ["cpu.max=max 50000"]),
    (#"{"quota": 0, "period": 250000}"#, ["cpu.max=max 250000"]),
    // Any negative quota is max.
    (#"{"quota": -1}"#, ["cpu.max=max 100000"]),
    (#"{"quota": -9223372036854775808, "period": 250000}"#, ["cpu.max=max 250000"]),
    // Extreme values are passed to the kernel unchanged, as runc does.
    (#"{"quota": 9223372036854775807, "period": 18446744073709551615}"#, ["cpu.max=9223372036854775807 18446744073709551615"]),
    (#"{"quota": 999, "period": 999}"#, ["cpu.max=999 999"]),
    // idle and burst are written whenever given, 0 included.
    (#"{"idle": 0}"#, ["cpu.idle=0"]),
    (#"{"idle": 1}"#, ["cpu.idle=1"]),
    (#"{"idle": -9223372036854775808}"#, ["cpu.idle=-9223372036854775808"]),
    (#"{"burst": 0}"#, ["cpu.max.burst=0"]),
    (#"{"burst": 18446744073709551615}"#, ["cpu.max.burst=18446744073709551615"]),
    (#"{"idle": 1, "shares": 1024}"#, ["cpu.idle=1", "cpu.weight=100"]),
    (
        #"{"idle": 0, "shares": 512, "burst": 10000, "quota": 50000, "period": 200000}"#,
        ["cpu.idle=0", "cpu.weight=59", "cpu.max.burst=10000", "cpu.max=50000 200000"]
    ),
])
func cpuWritesFollowRunc(_ cpu: String, _ expected: [String]) throws {
    let converted = try resources(#"{"cpu": "# + cpu + "}")
    #expect(converted.writes.map { "\($0.file)=\($0.value)" } == expected)
    #expect(converted.cpu.isSet)
    // CPU alone needs the cpu controller only, and counts as a domain
    // controller as in runc's containsDomainController.
    #expect(converted.requiredControllers == ["cpu"])
    #expect(converted.optionalControllers.isEmpty)
    #expect(converted.needsDomainController)
}

@Test func burstRetryNeedsANonzeroQuota() throws {
    func retried(_ cpu: String) throws -> Bool? {
        try resources(#"{"cpu": "# + cpu + "}").writes.first { $0.file == "cpu.max.burst" }?.retriedAfterCPUMax
    }
    #expect(try retried(#"{"burst": 1000, "quota": 50000}"#) == true)
    #expect(try retried(#"{"burst": 1000, "quota": -1}"#) == true)
    #expect(try retried(#"{"burst": 1000}"#) == false)
    // A period with a zero quota still writes cpu.max, but runc does not retry.
    #expect(try retried(#"{"burst": 1000, "quota": 0, "period": 100000}"#) == false)
    #expect(try resources(#"{"cpu": {"quota": 50000}}"#).writes.allSatisfy { !$0.retriedAfterCPUMax })
}

@Test func cpuFollowsPidsAndMemoryInRuncSetOrder() throws {
    let converted = try resources(#"{"cpu": {"quota": 20000, "idle": 0}, "memory": {"limit": 8192}, "pids": {"limit": 5}}"#)
    #expect(converted.writes.map(\.file) == ["pids.max", "memory.max", "cpu.idle", "cpu.max"])
    #expect(converted.requiredControllers == ["memory", "pids", "cpu"])
    #expect(try resources(#"{"cpu": {"shares": 1024}, "pids": {"limit": 5}}"#).requiredControllers == ["pids", "cpu"])
}

@Test(arguments: [
    (#"{"shares": -1}"#, "invalid value at linux.resources.cpu.shares"),
    (#"{"shares": 18446744073709551616}"#, "invalid value at linux.resources.cpu.shares"),
    (#"{"shares": 1.5}"#, "linux.resources.cpu.shares"),
    (#"{"shares": "1024"}"#, "linux.resources.cpu.shares"),
    (#"{"period": -1}"#, "invalid value at linux.resources.cpu.period"),
    (#"{"burst": -1}"#, "invalid value at linux.resources.cpu.burst"),
    (#"{"quota": 9223372036854775808}"#, "invalid value at linux.resources.cpu.quota"),
    (#"{"quota": "max"}"#, "linux.resources.cpu.quota"),
    (#"{"idle": -9223372036854775809}"#, "invalid value at linux.resources.cpu.idle"),
    (#"{"idle": true}"#, "linux.resources.cpu.idle"),
    (#"{"cpus": 1}"#, "linux.resources.cpu.cpus"),
    (#"{"mems": []}"#, "linux.resources.cpu.mems"),
    (#"[]"#, "linux.resources.cpu"),
])
func rejectsMalformedCpu(_ cpu: String, _ reason: String) {
    let message = rejection(#", "resources": {"cpu": "# + cpu + "}")
    #expect(message?.contains(reason) == true, "\(message ?? "accepted")")
}

/// Applies `json`'s writes through a fake cgroup whose files answer with
/// the listed errors in turn (then success); returns every attempted write
/// and the error, if any.
private func applied(_ json: String, answers: [String: [Errno]]) throws -> (writes: [String], error: String?) {
    let converted = try resources(json)
    var remaining = answers
    var writes: [String] = []
    do {
        try converted.apply(in: "/sys/fs/cgroup/test") { file, text in
            writes.append("\(file)=\(text)")
            guard var errors = remaining[file], !errors.isEmpty else { return nil }
            let error = errors.removeFirst()
            remaining[file] = errors
            return error
        }
        return (writes, nil)
    } catch {
        return (writes, "\(error)")
    }
}

private let einval = Errno.invalidArgument
private let enoent = Errno.noSuchFileOrDirectory

@Test func appliesEveryWriteInOrder() throws {
    let result = try applied(#"{"pids": {"limit": 5}, "cpu": {"idle": 0, "shares": 1024, "burst": 0, "quota": -1}}"#, answers: [:])
    #expect(result.error == nil)
    #expect(result.writes == ["pids.max=5", "cpu.idle=0", "cpu.weight=100", "cpu.max.burst=0", "cpu.max=max 100000"])
}

@Test func burstRefusedBeforeTheQuotaIsRetriedAfterCpuMax() throws {
    let burst = #"{"cpu": {"burst": 20000, "quota": 50000}}"#
    let retried = try applied(burst, answers: ["cpu.max.burst": [einval]])
    #expect(retried.error == nil)
    #expect(retried.writes == ["cpu.max.burst=20000", "cpu.max=50000 100000", "cpu.max.burst=20000"])
    // A second refusal is the error.
    let refused = try applied(burst, answers: ["cpu.max.burst": [einval, einval]])
    #expect(refused.writes.count == 3)
    #expect(refused.error?.contains("set /sys/fs/cgroup/test/cpu.max.burst to 20000") == true, "\(refused.error ?? "")")
    // A refused cpu.max is reported as such, without the retry.
    let quota = try applied(burst, answers: ["cpu.max.burst": [einval], "cpu.max": [einval]])
    #expect(quota.writes == ["cpu.max.burst=20000", "cpu.max=50000 100000"])
    #expect(quota.error?.contains("cpu.max to 50000 100000") == true, "\(quota.error ?? "")")
}

@Test(arguments: [
    // Without a quota, with a period but zero quota, or another errno: no retry.
    (#"{"cpu": {"burst": 20000}}"#, einval, ["cpu.max.burst=20000"]),
    (#"{"cpu": {"burst": 20000, "period": 100000}}"#, einval, ["cpu.max.burst=20000"]),
    (#"{"cpu": {"burst": 20000, "quota": 50000}}"#, enoent, ["cpu.max.burst=20000"]),
    (#"{"cpu": {"burst": 20000, "quota": 50000}}"#, Errno.permissionDenied, ["cpu.max.burst=20000"]),
] as [(String, Errno, [String])])
func burstRefusalWithoutRetryFailsAtOnce(_ json: String, _ error: Errno, _ writes: [String]) throws {
    let result = try applied(json, answers: ["cpu.max.burst": [error]])
    #expect(result.writes == writes)
    #expect(result.error?.contains("cpu.max.burst") == true, "\(result.error ?? "accepted")")
}

@Test func missingCpuFilesAreErrors() throws {
    // cpu.idle (Linux 5.15) and cpu.max.burst (5.14) are not optional.
    let idle = try applied(#"{"cpu": {"idle": 0, "shares": 1024}}"#, answers: ["cpu.idle": [enoent]])
    #expect(idle.writes == ["cpu.idle=0"])
    #expect(idle.error?.contains("does not exist in this kernel or cgroup") == true, "\(idle.error ?? "accepted")")
    // An idle group refuses a weight; nothing after it is written.
    let weight = try applied(#"{"cpu": {"idle": 1, "shares": 1024, "quota": 1000}}"#, answers: ["cpu.weight": [einval]])
    #expect(weight.writes == ["cpu.idle=1", "cpu.weight=100"])
    #expect(weight.error?.contains("cpu.weight to 100") == true, "\(weight.error ?? "accepted")")
    // The ignorable swap write still tolerates a missing file.
    let swap = try applied(#"{"memory": {"swap": -1}, "cpu": {"quota": 1000}}"#, answers: ["memory.swap.max": [enoent]])
    #expect(swap.error == nil)
    #expect(swap.writes == ["memory.swap.max=max", "cpu.max=1000 100000"])
}

@Test func swapConversionMatchesRuncTable() throws {
    #expect(try CgroupPlan.convertSwap(memorySwap: 0, memory: -1) == .max)
    #expect(try CgroupPlan.convertSwap(memorySwap: 0, memory: 0) == nil)
    #expect(try CgroupPlan.convertSwap(memorySwap: 0, memory: 4096) == nil)
    #expect(try CgroupPlan.convertSwap(memorySwap: -1, memory: 0) == .max)
    #expect(try CgroupPlan.convertSwap(memorySwap: 8192, memory: 4096) == .number(4096))
    #expect(try CgroupPlan.convertSwap(memorySwap: Int64.max, memory: 1) == .number(UInt64(Int64.max - 1)))
}

// MARK: Identity

@Test(arguments: [
    ("/swift-container-runtime/box", UInt64(42), "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0", true),
    ("/swift-container-runtime/box", 42, "", false),
    ("/swift-container-runtime/box", 42, "../../../../sys/fs/cgroup/xxxxxxxxxx", false),
    ("/", 42, "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0", false),
    ("/a/../b", 42, "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0", false),
])
func validatesCgroupIdentities(_ path: String, _ inode: UInt64, _ bootID: String, _ valid: Bool) {
    #expect(CgroupIdentity(path: path, inode: inode, bootID: bootID, created: true).isValid == valid)
}
