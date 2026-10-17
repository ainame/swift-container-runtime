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
    (#"{"cpu": {"shares": 1024}}"#, "linux.resources.cpu"),
    (#"{"devices": [{"allow": false, "access": "rwm"}]}"#, "linux.resources.devices"),
    (#"{"blockIO": {}}"#, "linux.resources.blockIO"),
    (#"{"hugepageLimits": []}"#, "linux.resources.hugepageLimits"),
    (#"{"unified": {}}"#, "linux.resources.unified"),
    (#"{"memory": {"swappiness": 0}}"#, "linux.resources.memory.swappiness"),
    (#"{"memory": {"disableOOMKiller": true}}"#, "linux.resources.memory.disableOOMKiller"),
    (#"{"memory": {"checkBeforeUpdate": true}}"#, "linux.resources.memory.checkBeforeUpdate"),
    (#"{"memory": {"kernel": 1}}"#, "linux.resources.memory.kernel"),
    (#"{"pids": {"limit": 1, "max": 2}}"#, "linux.resources.pids.max"),
])
func rejectsInvalidAndUnsupportedResources(_ json: String, _ reason: String) {
    let message = rejection(#", "resources": "# + json)
    #expect(message?.contains(reason) == true, "\(message ?? "accepted")")
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
