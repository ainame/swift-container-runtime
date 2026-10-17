import SystemPackage
import Testing
@testable import ContainerRuntime

private func plan(rlimits: String?) throws -> OCIRunPlan {
    let field = rlimits.map { #", "rlimits": "# + $0 } ?? ""
    let json = """
    {"ociVersion": "1.2.0", "root": {"path": "rootfs"},
     "process": {"args": ["/bin/sh"], "cwd": "/"\(field)},
     "linux": {"namespaces": [{"type": "mount"}]}}
    """
    let configuration = try OCIConfiguration.decode(Array(json.utf8))
    return try OCIRunPlan(configuration, bundle: FilePath("/bundle"), rootfs: FilePath("/bundle/rootfs"))
}

private func limit(_ resource: ResourceLimit.Resource, _ soft: UInt64, _ hard: UInt64) -> ResourceLimit {
    ResourceLimit(resource: resource, soft: soft, hard: hard)
}

@Test func knowsEveryLinuxRlimitNameAndNumber() {
    // The sixteen names in runc's rlimitMap and kontainer-runtime's RlimitType.
    let names = ResourceLimit.Resource.allCases.map(\.rawValue)
    #expect(names.count == 16)
    #expect(Set(names).count == 16)
    #expect(ResourceLimit.Resource.allCases.map(\.number) == Array(0...15))
    #expect(ResourceLimit.Resource(rawValue: "RLIMIT_NOFILE")?.number == 7)
    #expect(ResourceLimit.Resource(rawValue: "RLIMIT_AS")?.number == 9)
    #expect(ResourceLimit.Resource(rawValue: "RLIMIT_RTTIME")?.number == 15)
    #expect(limit(.nofile, 32, ResourceLimit.infinity).description == "RLIMIT_NOFILE soft 32 hard unlimited")
}

@Test func absentNullAndEmptyRlimitsInheritEverything() throws {
    for json in [nil, "null", "[]"] {
        #expect(try plan(rlimits: json).resourceLimits.isEmpty)
    }
}

@Test func parsesSoftHardAndInfinity() throws {
    let json = """
    [{"type": "RLIMIT_NOFILE", "soft": 64, "hard": 128},
     {"type": "RLIMIT_CORE", "soft": 0, "hard": 0},
     {"type": "RLIMIT_STACK", "soft": 8388608, "hard": 18446744073709551615},
     {"type": "RLIMIT_CPU", "soft": 18446744073709551615, "hard": 18446744073709551615}]
    """
    #expect(try plan(rlimits: json).resourceLimits == [
        limit(.nofile, 64, 128),
        limit(.core, 0, 0),
        limit(.stack, 8_388_608, ResourceLimit.infinity),
        limit(.cpu, ResourceLimit.infinity, ResourceLimit.infinity),
    ])
    #expect(ResourceLimit.describe(ResourceLimit.infinity) == "unlimited")
    #expect(ResourceLimit.describe(UInt64.max - 1) == "18446744073709551614")
}

@Test func acceptsAllSixteenTypes() throws {
    let entries = ResourceLimit.Resource.allCases.map { #"{"type": "\#($0.rawValue)", "soft": 1, "hard": 2}"# }
    let limits = try plan(rlimits: "[" + entries.joined(separator: ", ") + "]").resourceLimits
    #expect(limits.map(\.resource) == ResourceLimit.Resource.allCases)
}

@Test func repeatedTypesStayInInputOrder() throws {
    // runc converts the list one-to-one and sets each entry in turn, so an
    // earlier entry (here an unlimited RLIMIT_NOFILE the kernel refuses)
    // must still be applied and can fail setup.
    let json = """
    [{"type": "RLIMIT_NOFILE", "soft": 18446744073709551615, "hard": 18446744073709551615},
     {"type": "RLIMIT_FSIZE", "soft": 1, "hard": 1},
     {"type": "RLIMIT_NOFILE", "soft": 30, "hard": 40},
     {"type": "RLIMIT_NOFILE", "soft": 30, "hard": 40}]
    """
    #expect(try plan(rlimits: json).resourceLimits == [
        limit(.nofile, ResourceLimit.infinity, ResourceLimit.infinity),
        limit(.fsize, 1, 1),
        limit(.nofile, 30, 40),
        limit(.nofile, 30, 40),
    ])
}

@Test(arguments: [
    (#"[{"type": "RLIMIT_NOPE", "soft": 1, "hard": 1}]"#, "process.rlimits[0].type RLIMIT_NOPE is not a Linux rlimit"),
    (#"[{"type": "nofile", "soft": 1, "hard": 1}]"#, "not a Linux rlimit"),
    (#"[{"type": "RLIMIT_NOFILE", "soft": 2, "hard": 1}]"#, "RLIMIT_NOFILE soft limit 2 exceeds hard limit 1"),
    (#"[{"type": "RLIMIT_CPU", "soft": 18446744073709551615, "hard": 5}]"#, "soft limit unlimited exceeds hard limit 5"),
    // Every entry is validated, including one a later entry of its type follows.
    (#"[{"type": "RLIMIT_NOFILE", "soft": 9, "hard": 1}, {"type": "RLIMIT_NOFILE", "soft": 1, "hard": 1}]"#, "process.rlimits[0]"),
    (#"[{"type": "RLIMIT_CORE", "soft": 0, "hard": 0}, {"type": "RLIMIT_X", "soft": 0, "hard": 0}]"#, "process.rlimits[1].type"),
    (#"[{"type": "RLIMIT_NOFILE", "hard": 1}]"#, "missing required field process.rlimits[0].soft"),
    (#"[{"type": "RLIMIT_NOFILE", "soft": 1}]"#, "missing required field process.rlimits[0].hard"),
    (#"[{"soft": 1, "hard": 1}]"#, "missing required field process.rlimits[0].type"),
    (#"[{"type": "RLIMIT_NOFILE", "soft": -1, "hard": 1}]"#, "process.rlimits[0].soft"),
    (#"[{"type": "RLIMIT_NOFILE", "soft": 1.5, "hard": 2}]"#, "process.rlimits[0].soft"),
    (#"[{"type": "RLIMIT_NOFILE", "soft": 1, "hard": 18446744073709551616}]"#, "process.rlimits[0].hard"),
    (#"[{"type": "RLIMIT_NOFILE", "soft": "1", "hard": 1}]"#, "process.rlimits[0].soft"),
    (#"[{"type": "RLIMIT_NOFILE", "soft": 1, "hard": 1, "extra": 0}]"#, "unsupported field(s): process.rlimits[0].extra"),
    (#"{"type": "RLIMIT_NOFILE", "soft": 1, "hard": 1}"#, "process.rlimits"),
])
func rejectsInvalidRlimits(_ json: String, _ reason: String) {
    do {
        _ = try plan(rlimits: json)
        Issue.record("Expected rejection mentioning \(reason)")
    } catch let error as RuntimeError {
        #expect(error.description.contains(reason), "\(error.description)")
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}
