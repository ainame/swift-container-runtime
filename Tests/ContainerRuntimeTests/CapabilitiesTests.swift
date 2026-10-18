import SystemPackage
import Testing
@testable import ContainerRuntime

private func plan(capabilities: String?) throws -> OCIRunPlan {
    let field = capabilities.map { #", "capabilities": "# + $0 } ?? ""
    let json = """
    {"ociVersion": "1.2.0", "root": {"path": "rootfs"},
     "process": {"args": ["/bin/sh"], "cwd": "/"\(field)},
     "linux": {"namespaces": [{"type": "mount"}]}}
    """
    let configuration = try OCIConfiguration.decode(Array(json.utf8))
    return try OCIRunPlan(configuration, bundle: FilePath("/bundle"), rootfs: FilePath("/bundle/rootfs"))
}

private func set(_ names: String...) -> CapabilitySet {
    CapabilitySet(mask: names.reduce(UInt64(0)) { $0 | 1 << UInt64(CapabilitySet.number(named: $1)!) })
}

@Test func knowsKernelCapabilityNumbers() {
    #expect(CapabilitySet.knownNames.count == 41)
    #expect(CapabilitySet.number(named: "CAP_CHOWN") == 0)
    #expect(CapabilitySet.number(named: "CAP_SETPCAP") == 8)
    #expect(CapabilitySet.number(named: "CAP_SYS_ADMIN") == 21)
    #expect(CapabilitySet.number(named: "CAP_MKNOD") == 27)
    #expect(CapabilitySet.number(named: "CAP_AUDIT_READ") == 37)
    #expect(CapabilitySet.number(named: "CAP_CHECKPOINT_RESTORE") == 40)
    #expect(Set(CapabilitySet.knownNames).count == CapabilitySet.knownNames.count)
    #expect(set("CAP_KILL", "CAP_CHOWN").names == ["CAP_CHOWN", "CAP_KILL"])
    #expect(set("CAP_BPF").mask == 1 << 39)
}

@Test func absentCapabilitiesKeepInheritedSets() throws {
    // runc leaves the sets alone without the object; so does a JSON null.
    #expect(try plan(capabilities: nil).capabilities == nil)
    #expect(try plan(capabilities: "null").capabilities == nil)
}

@Test func emptyCapabilitiesAreAuthoritative() throws {
    // `{}` and empty members both mean "no capabilities", bounding included.
    for json in ["{}", #"{"bounding": [], "effective": [], "inheritable": [], "permitted": [], "ambient": []}"#] {
        let capabilities = try #require(try plan(capabilities: json).capabilities)
        #expect(capabilities.requested.isEmpty)
        #expect(capabilities.bounding.isEmpty)
    }
}

@Test func parsesAllFiveSets() throws {
    let json = """
    {"bounding": ["CAP_CHOWN", "CAP_NET_BIND_SERVICE", "CAP_KILL", "CAP_CHOWN"],
     "permitted": ["CAP_NET_BIND_SERVICE", "CAP_KILL", "CAP_SYS_ADMIN"],
     "effective": ["CAP_KILL"],
     "inheritable": ["CAP_NET_BIND_SERVICE"],
     "ambient": ["CAP_NET_BIND_SERVICE"]}
    """
    let capabilities = try #require(try plan(capabilities: json).capabilities)
    #expect(capabilities.bounding == set("CAP_CHOWN", "CAP_NET_BIND_SERVICE", "CAP_KILL"))
    // Like runc, permitted may exceed bounding; exec then drops the excess.
    #expect(capabilities.permitted == set("CAP_NET_BIND_SERVICE", "CAP_KILL", "CAP_SYS_ADMIN"))
    #expect(capabilities.effective == set("CAP_KILL"))
    #expect(capabilities.inheritable == set("CAP_NET_BIND_SERVICE"))
    #expect(capabilities.ambient == set("CAP_NET_BIND_SERVICE"))
}

@Test func leavesInheritableOutsideBoundingToTheKernel() throws {
    // capset(2) keeps an inherited inheritable bit outside the reduced
    // bounding set, and runc does not check this relation either.
    let json = """
    {"bounding": ["CAP_CHOWN"], "permitted": ["CAP_NET_RAW"], "effective": ["CAP_NET_RAW"],
     "inheritable": ["CAP_NET_RAW"], "ambient": ["CAP_NET_RAW"]}
    """
    let capabilities = try #require(try plan(capabilities: json).capabilities)
    #expect(capabilities.inheritable.subtracting(capabilities.bounding) == set("CAP_NET_RAW"))
    #expect(capabilities.ambient == set("CAP_NET_RAW"))
}

@Test(arguments: [
    (#"{"bounding": ["CAP_FOO"]}"#, "process.capabilities.bounding[0]: unknown capability \"CAP_FOO\"; names are exact, such as CAP_CHOWN"),
    (#"{"effective": ["CAP_KILL", "cap_chown"], "permitted": ["CAP_KILL", "CAP_CHOWN"]}"#, "effective[1]: unknown capability \"cap_chown\"; names are exact, did you mean CAP_CHOWN?"),
    (#"{"permitted": ["NET_RAW"]}"#, "did you mean CAP_NET_RAW?"),
    (#"{"ambient": [""]}"#, "process.capabilities.ambient[0]: unknown capability"),
    (#"{"inheritable": [" CAP_KILL"]}"#, "inheritable[0]"),
    (#"{"bounding": "CAP_KILL"}"#, "invalid value at process.capabilities.bounding"),
    (#"{"bounding": [1]}"#, "invalid value at process.capabilities.bounding"),
    (#"[]"#, "invalid value at process.capabilities"),
    (#"{"effective": ["CAP_KILL", "CAP_CHOWN"], "permitted": ["CAP_KILL"]}"#, "effective must be a subset of permitted; add to permitted or remove from effective: CAP_CHOWN"),
    (#"{"bounding": ["CAP_KILL"], "inheritable": ["CAP_KILL"], "ambient": ["CAP_KILL"]}"#, "ambient must be a subset of both permitted and inheritable; not permitted: CAP_KILL"),
    (#"{"bounding": ["CAP_KILL"], "permitted": ["CAP_KILL", "CAP_CHOWN"], "ambient": ["CAP_KILL", "CAP_CHOWN"]}"#, "not inheritable: CAP_CHOWN, CAP_KILL"),
    (#"{"bounding": ["CAP_KILL"], "ambient": ["CAP_KILL"]}"#, "not permitted: CAP_KILL; not inheritable: CAP_KILL"),
    (#"{"bounding": [], "extra": []}"#, "unsupported field(s): process.capabilities.extra"),
])
func rejectsInvalidCapabilities(_ json: String, _ reason: String) {
    do {
        _ = try plan(capabilities: json)
        Issue.record("Expected rejection mentioning \(reason)")
    } catch let error as RuntimeError {
        #expect(error.description.contains(reason), "\(error.description)")
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test func checksKernelRange() throws {
    let capabilities = try #require(try plan(capabilities: #"{"bounding": ["CAP_CHOWN", "CAP_BPF", "CAP_CHECKPOINT_RESTORE"]}"#).capabilities)
    try capabilities.checkSupported(lastCapability: 40)
    do {
        try capabilities.checkSupported(lastCapability: 38)
        Issue.record("Expected capabilities above cap_last_cap to be rejected")
    } catch let error as RuntimeError {
        #expect(error.description.contains("CAP_BPF (39), CAP_CHECKPOINT_RESTORE (40) not supported by this kernel (cap_last_cap is 38)"), "\(error.description)")
    }
}

@Test func parsesLastCapability() throws {
    #expect(try ProcessCapabilities.parseLastCapability(Array("40\n".utf8)) == 40)
    #expect(try ProcessCapabilities.parseLastCapability(Array("0".utf8)) == 0)
    for bad in ["", "\n", "-1\n", "4 0\n", "64\n", "1000\n", "x\n"] {
        #expect(throws: RuntimeError.self) { try ProcessCapabilities.parseLastCapability(Array(bad.utf8)) }
    }
}

/// The final sets after exec --cap, as loadExec validates them.
private func execSets(_ configured: String?, adding names: [String]) throws -> ProcessCapabilities? {
    // A standalone process object, so only the process fields are decoded.
    let field = configured.map { #", "capabilities": "# + $0 } ?? ""
    let json = #"{"args": ["/bin/sh"], "cwd": "/""# + field + "}"
    var process = try OCIConfiguration.decodeProcess(Array(json.utf8))
    if !names.isEmpty { process.capabilities = try OCIRunPlan.execCapabilities(process.capabilities, adding: names) }
    return try process.capabilities.map(ProcessCapabilities.init)
}

@Test func execCapabilitiesAppendLikeRunc() throws {
    // No request leaves an absent object absent, so inherited sets are kept.
    #expect(try execSets(nil, adding: []) == nil)
    // An absent object starts empty; inheritable stays absent, so no ambient.
    let fresh = try #require(try execSets(nil, adding: ["CAP_KILL", "CAP_KILL"]))
    #expect(fresh.bounding == set("CAP_KILL") && fresh.effective == set("CAP_KILL") && fresh.permitted == set("CAP_KILL"))
    #expect(fresh.inheritable.isEmpty && fresh.ambient.isEmpty)
    // Configured sets are kept; inheritable is never extended.
    let configured = """
    {"bounding": ["CAP_CHOWN"], "effective": ["CAP_CHOWN"], "permitted": ["CAP_CHOWN"],
     "inheritable": ["CAP_NET_BIND_SERVICE"], "ambient": []}
    """
    let merged = try #require(try execSets(configured, adding: ["CAP_NET_BIND_SERVICE", "CAP_KILL"]))
    #expect(merged.bounding == set("CAP_CHOWN", "CAP_NET_BIND_SERVICE", "CAP_KILL"))
    #expect(merged.effective == merged.bounding && merged.permitted == merged.bounding)
    #expect(merged.inheritable == set("CAP_NET_BIND_SERVICE"))
    // With inheritable present, only requests the kernel could raise become
    // ambient: what runc ends with after warning about the others.
    #expect(merged.ambient == set("CAP_NET_BIND_SERVICE"))
    // An explicitly empty inheritable set is runc's non-nil empty slice.
    let empty = try #require(try execSets(#"{"inheritable": []}"#, adding: ["CAP_KILL"]))
    #expect(empty.ambient.isEmpty && empty.permitted == set("CAP_KILL"))
}

@Test(arguments: ["cap_kill", "KILL", "CAP_UNKNOWN", ""])
func execRejectsUnknownCapabilityNames(_ name: String) throws {
    // The same fixture accepts a valid request, so only the name can fail.
    #expect(try execSets(nil, adding: ["CAP_KILL"]) != nil)
    do {
        _ = try execSets(nil, adding: ["CAP_KILL", name])
        Issue.record("Expected exec --cap \(name) to be rejected")
    } catch let error as RuntimeError {
        #expect(error.description.contains(#"exec --cap: unknown capability "\#(name)""#), "\(error.description)")
    }
}
