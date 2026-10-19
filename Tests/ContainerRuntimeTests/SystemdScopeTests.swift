import SystemPackage
import Testing
@testable import ContainerRuntime

private let box = try! ContainerID("box")

private func plan(_ linuxFields: String, driver: CgroupDriver = .systemd) throws -> OCIRunPlan {
    let json = """
    {"ociVersion": "1.2.0", "root": {"path": "rootfs"},
     "process": {"args": ["/bin/sh"], "cwd": "/"},
     "linux": {"namespaces": [{"type": "mount"}]\(linuxFields)}}
    """
    let configuration = try OCIConfiguration.decode(Array(json.utf8))
    return try OCIRunPlan(configuration, bundle: FilePath("/bundle"), rootfs: FilePath("/bundle/rootfs"), cgroupDriver: driver)
}

// MARK: Scope names

@Test(arguments: [
    // Docker's form, nested slices, the root slice, no prefix, and the default.
    (#", "cgroupsPath": "system.slice:docker:abc""#, ["system.slice", "docker-abc.scope"]),
    (#", "cgroupsPath": "machine-pods.slice:crio:x1""#, ["machine.slice", "machine-pods.slice", "crio-x1.scope"]),
    (#", "cgroupsPath": "-.slice:p:n""#, ["p-n.scope"]),
    (#", "cgroupsPath": "user.slice::solo""#, ["user.slice", "solo.scope"]),
    (#", "cgroupsPath": ":docker:abc""#, ["system.slice", "docker-abc.scope"]),
    ("", ["system.slice", "swift-container-runtime-box.scope"]),
    (#", "cgroupsPath": """#, ["system.slice", "swift-container-runtime-box.scope"]),
])
func resolvesSystemdScopes(_ fields: String, _ components: [String]) throws {
    #expect(try plan(fields).cgroup.components(for: box) == components)
}

@Test(arguments: [
    (#", "cgroupsPath": "/sys/a""#, "slice:prefix:name"),
    (#", "cgroupsPath": "a:b""#, "slice:prefix:name"),
    (#", "cgroupsPath": "system.slice:docker:""#, "names no scope"),
    (#", "cgroupsPath": "system.slice:docker:sub.slice""#, "slice unit"),
    (#", "cgroupsPath": "system:docker:abc""#, "slice"),
    (#", "cgroupsPath": "a--b.slice:docker:abc""#, "slice"),
    (#", "cgroupsPath": "-a.slice:docker:abc""#, "slice"),
    (#", "cgroupsPath": "system.slice:dock/er:abc""#, "invalid"),
    (#", "cgroupsPath": "system.slice:docker:a b""#, "invalid"),
])
func rejectsInvalidSystemdPaths(_ fields: String, _ reason: String) {
    do {
        _ = try plan(fields)
        Issue.record("accepted \(fields)")
    } catch {
        #expect("\(error)".contains(reason), "\(error)")
    }
}

@Test func validatesTheContainerIDAsAUnitName() throws {
    // ContainerID allows "+", which systemd unit names do not.
    let request = SystemdScopeRequest(slice: "system.slice", prefix: "p", name: nil)
    #expect(try request.scope(id: box).unit == "p-box.scope")
    #expect(throws: (any Error).self) { try request.scope(id: try ContainerID("a+b")) }
}

@Test func cgroupfsDriverStillRejectsTuples() {
    #expect(throws: (any Error).self) { try plan(#", "cgroupsPath": "system.slice:docker:abc""#, driver: .cgroupfs) }
}

// MARK: Resource properties

private func properties(_ resources: String) throws -> [String: DBusValue] {
    let resources = try plan(#", "resources": "# + resources).cgroup.resources
    return Dictionary(uniqueKeysWithValues: try SystemdResourceProperties.properties(for: resources))
}

@Test func mapsResourcesToUnitProperties() throws {
    let mapped = try properties("""
    {"memory": {"limit": 1048576, "reservation": 524288, "swap": -1}, "pids": {"limit": 64},
     "cpu": {"shares": 1024, "quota": 50000, "period": 100000, "cpus": "0-2,5", "mems": "0"}}
    """)
    #expect(mapped["MemoryMax"] == .uint64(1_048_576))
    #expect(mapped["MemoryLow"] == .uint64(524_288))
    #expect(mapped["MemorySwapMax"] == .uint64(.max))
    #expect(mapped["TasksMax"] == .uint64(64))
    // The weight is the cpu.weight value this runtime converts from shares.
    #expect(mapped["CPUWeight"] == .uint64(100))
    #expect(mapped["CPUQuotaPerSecUSec"] == .uint64(500_000))
    #expect(mapped["CPUQuotaPeriodUSec"] == .uint64(100_000))
    #expect(mapped["AllowedCPUs"] == .array(element: "y", [.byte(0b0010_0111)]))
    #expect(mapped["AllowedMemoryNodes"] == .array(element: "y", [.byte(1)]))
}

@Test func unsetResourcesAddNoProperties() throws {
    #expect(try properties("{}").isEmpty)
    // Unlimited values are systemd's infinity.
    let unlimited = try properties(#"{"memory": {"limit": -1}, "pids": {"limit": -1}, "cpu": {"quota": -1, "period": 100000}}"#)
    #expect(unlimited["MemoryMax"] == .uint64(.max))
    #expect(unlimited["TasksMax"] == .uint64(.max))
    #expect(unlimited["CPUQuotaPerSecUSec"] == .uint64(.max))
}

@Test(arguments: [
    // runc rounds the per-second quota up to whole 10 ms.
    (Int64?(100_000), UInt64(100_000), UInt64(1_000_000)),
    (Int64?(12_345), UInt64(100_000), UInt64(130_000)),
    (Int64?(1), UInt64(1_000_000), UInt64(10_000)),
    (Int64?(nil), UInt64(100_000), UInt64.max),
    (Int64?(Int64.max), UInt64(1), UInt64.max),
])
func convertsQuotaPerSecond(_ quota: Int64?, _ period: UInt64, _ expected: UInt64) {
    #expect(SystemdResourceProperties.quotaPerSecond(quota: quota, period: period) == expected)
}

@Test func buildsCPUMasks() throws {
    #expect(try SystemdResourceProperties.bitmask("0", field: "cpus") == [1])
    #expect(try SystemdResourceProperties.bitmask("8-9", field: "cpus") == [0, 3])
    #expect(try SystemdResourceProperties.bitmask("0, 3", field: "cpus") == [9])
    for invalid in ["", "a", "3-1", "1-2-3", "-1", "999999"] {
        #expect(throws: (any Error).self) { try SystemdResourceProperties.bitmask(invalid, field: "cpus") }
    }
}

// MARK: Records

@Test func recordsPendingAndStartedScopes() {
    let boot = "01234567-89ab-cdef-0123-456789abcdef"
    let pending = CgroupIdentity(path: "/system.slice/a.scope", inode: 0, bootID: boot, created: true, systemdUnit: "a.scope")
    #expect(pending.isValid)
    #expect(pending.isPendingSystemdScope)
    let started = CgroupIdentity(path: "/system.slice/a.scope", inode: 9, bootID: boot, created: true, systemdUnit: "a.scope")
    #expect(started.isValid)
    #expect(!started.isPendingSystemdScope)
    // The unit must be the recorded path's last component, and cgroupfs
    // records still need an inode.
    #expect(!CgroupIdentity(path: "/system.slice/a.scope", inode: 9, bootID: boot, created: true, systemdUnit: "b.scope").isValid)
    #expect(!CgroupIdentity(path: "/x", inode: 0, bootID: boot, created: true).isValid)
}
