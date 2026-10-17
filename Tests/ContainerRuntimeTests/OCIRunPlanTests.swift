import SystemPackage
import Testing
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import ContainerRuntime

private let defaultProcess = """
{"terminal": false, "user": {"uid": 0, "gid": 0}, "args": ["/bin/sh", "-c", "echo hi"],
 "env": ["PATH=/bin", "GREETING=a=b c"], "cwd": "/work/dir"}
"""

private let defaultMounts = """
[{"destination": "/proc", "type": "proc", "source": "proc", "options": ["nosuid", "noexec", "nodev"]},
 {"destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]},
 {"destination": "/dev/pts", "type": "devpts", "source": "devpts",
  "options": ["nosuid", "noexec", "newinstance", "ptmxmode=0666", "mode=0620", "gid=5"]}]
"""

private let defaultLinux = """
{"namespaces": [{"type": "pid"}, {"type": "mount"}, {"type": "uts"}, {"type": "ipc"}], "rootfsPropagation": "rprivate"}
"""

private func config(
    version: String = "\"1.2.0\"",
    root: String = #"{"path": "rootfs", "readonly": false}"#,
    process: String = defaultProcess,
    hostname: String = "\"ocibox\"",
    mounts: String = defaultMounts,
    linux: String = defaultLinux,
    extra: String = #""annotations": {"org.example": "ignored"}"#
) -> String {
    """
    {"ociVersion": \(version), "root": \(root), "process": \(process), "hostname": \(hostname),
     "mounts": \(mounts), "linux": \(linux)\(extra.isEmpty ? "" : ", " + extra)}
    """
}

private func plan(_ json: String) throws -> OCIRunPlan {
    let configuration = try OCIConfiguration.decode(Array(json.utf8))
    return try OCIRunPlan(configuration, bundle: FilePath("/bundle"), rootfs: FilePath("/bundle/rootfs"))
}

private func pathControls(_ fields: String) -> String {
    #"{"namespaces": [{"type": "pid"}, {"type": "mount"}, {"type": "uts"}], "# + fields + "}"
}

@Test func buildsPathControls() throws {
    let controlled = try plan(config(linux: pathControls(#"""
        "readonlyPaths": ["/proc/sys", "//proc//sys/", "/proc/sys/kernel", "/missing"],
        "maskedPaths": ["/proc/kcore", "/proc/acpi", "/proc/kcore/", "/proc/acpi/x"]
        """#)))
    // Canonical spelling and input order. Read-only repeats are kept, as runc
    // binds them again; a masked repeat is applied once, as in runc.
    #expect(controlled.pathControls.readonly == ["/proc/sys", "/proc/sys", "/proc/sys/kernel", "/missing"])
    #expect(controlled.pathControls.masked == ["/proc/kcore", "/proc/acpi", "/proc/acpi/x"])
    let absent = try plan(config())
    #expect(absent.pathControls.readonly.isEmpty && absent.pathControls.masked.isEmpty)
    // Setup mounts through descriptors, so no proc mount is needed, and "/"
    // is a valid entry whose effect runc's own lookup semantics decide.
    let empty = try plan(config(mounts: "[]", linux: pathControls(#""readonlyPaths": [], "maskedPaths": []"#)))
    #expect(empty.pathControls.readonly.isEmpty && empty.pathControls.masked.isEmpty)
    let unmounted = try plan(config(mounts: "[]", linux: pathControls(#""readonlyPaths": ["/", "//"], "maskedPaths": ["/", "/etc/x"]"#)))
    #expect(unmounted.pathControls.readonly == ["/", "/"])
    #expect(unmounted.pathControls.masked == ["/", "/etc/x"])
}

@Test func buildsPlanFromSupportedSubset() throws {
    let plan = try plan(config())
    #expect(plan.arguments == ["/bin/sh", "-c", "echo hi"])
    #expect(plan.environment == ["PATH=/bin", "GREETING=a=b c"])
    #expect(plan.cwd == ["work", "dir"])
    #expect(plan.hostname == "ocibox")
    #expect(plan.namespaces == [.pid, .mount, .uts, .ipc])
    #expect(plan.populatesDev)
    #expect(plan.mounts.map(\.destinationPath) == ["/proc", "/dev", "/dev/pts"])
    #expect(plan.mounts[0].flags == [.nosuid, .noexec, .nodev])
    #expect(plan.mounts[1].flags == [.nosuid, .strictatime])
    #expect(plan.mounts[1].data == "mode=755,size=65536k")
    #expect(plan.mounts[2].data == "newinstance,ptmxmode=0666,mode=0620,gid=5")
}

@Test(arguments: [
    (#"{"path": "rootfs", "readonly": true}"#, true),
    (#"{"path": "rootfs", "readonly": false}"#, false),
    (#"{"path": "rootfs"}"#, false),
])
func readsRootReadonly(root: String, readonly: Bool) throws {
    #expect(try plan(config(root: root)).readonlyRoot == readonly)
}

@Test func rejectsNonBooleanRootReadonly() {
    #expect(throws: (any Error).self) { try plan(config(root: #"{"path": "rootfs", "readonly": "true"}"#)) }
}

@Test func minimalConfigUsesEmptyEnvironmentAndNoDevSetup() throws {
    let plan = try plan(config(
        process: #"{"args": ["/bin/true"], "cwd": "/"}"#, hostname: "null", mounts: "[]",
        linux: #"{"namespaces": [{"type": "mount"}]}"#, extra: ""
    ))
    #expect(plan.environment.isEmpty)
    #expect(plan.cwd.isEmpty)
    #expect(plan.hostname == nil)
    #expect(!plan.populatesDev)
    // Without process.user: root, no supplementary groups, runc's umask.
    #expect(plan.security == OCIRunPlan.ProcessSecurity(
        uid: 0, gid: 0, additionalGids: [], umask: 0o022, noNewPrivileges: false
    ))
}

@Test func buildsProcessSecurity() throws {
    let configured = try plan(config(process: """
    {"user": {"uid": 1000, "gid": 1001, "umask": 63, "additionalGids": [5, 1001, 5]},
     "noNewPrivileges": true, "args": ["/bin/id"], "cwd": "/"}
    """))
    // Groups keep their order and duplicates, as setgroups receives them.
    #expect(configured.security == OCIRunPlan.ProcessSecurity(
        uid: 1000, gid: 1001, additionalGids: [5, 1001, 5], umask: 0o077, noNewPrivileges: true
    ))
    let explicit = try plan(config(process: """
    {"user": {"uid": 0, "gid": 0, "umask": 0, "additionalGids": []}, "noNewPrivileges": false,
     "args": ["/bin/id"], "cwd": "/"}
    """))
    #expect(explicit.security.umask == 0)
    #expect(explicit.security.additionalGids.isEmpty)
    #expect(!explicit.security.noNewPrivileges)
}

@Test func limitsSupplementaryGroups() throws {
    func process(groups count: Int) -> String {
        let groups = Array(repeating: "7", count: count).joined(separator: ",")
        return #"{"user": {"uid": 1, "gid": 1, "additionalGids": ["# + groups + #"]}, "args": ["/bin/id"], "cwd": "/"}"#
    }
    #expect(try plan(config(process: process(groups: 65_536))).security.additionalGids.count == 65_536)
    #expect(throws: RuntimeError.self) { try plan(config(process: process(groups: 65_537))) }
}

@Test(arguments: [
    // Unknown or unimplemented fields are rejected wherever they appear.
    (config(extra: #""hooks": {}"#), "hooks"),
    (config(extra: #""futureField": 1"#), "futureField"),
    (config(process: #"{"args": ["/bin/true"], "cwd": "/", "capabilities": {"permited": []}}"#), "process.capabilities.permited"),
    (config(process: #"{"args": ["/bin/true"], "cwd": "/", "oomScoreAdj": 100}"#), "process.oomScoreAdj"),
    (config(process: #"{"args": ["/bin/true"], "cwd": "/", "user": {"uid": 0, "gid": 0, "username": "root"}}"#), "process.user.username"),
    (config(process: #"{"args": ["/bin/true"], "cwd": "/", "apparmorProfile": "x"}"#), "process.apparmorProfile"),
    (config(linux: #"{"namespaces": [{"type": "mount"}], "sysctl": {"net.ipv4.ip_forward": "1"}}"#), "linux.sysctl"),
    (config(linux: #"{"namespaces": [{"type": "mount"}], "resources": {}}"#), "linux.resources"),
    (config(linux: #"{"namespaces": [{"type": "mount"}], "seccomp": {}}"#), "linux.seccomp"),
    (config(linux: #"{"namespaces": [{"type": "mount", "path": "/proc/1/ns/mnt"}]}"#), "path"),
    (config(mounts: #"[{"destination": "/x", "type": "tmpfs", "uidMappings": []}]"#), "uidMappings"),
    // Known fields with unimplemented values.
    (config(process: #"{"terminal": true, "args": ["/bin/sh"], "cwd": "/"}"#), "terminal"),
    (config(process: #"{"user": {"uid": 4294967295, "gid": 0}, "args": ["/bin/sh"], "cwd": "/"}"#), "unchanged"),
    (config(process: #"{"user": {"uid": 0, "gid": 4294967295}, "args": ["/bin/sh"], "cwd": "/"}"#), "unchanged"),
    (config(process: #"{"user": {"uid": 0, "gid": 0, "additionalGids": [4294967295]}, "args": ["/bin/sh"], "cwd": "/"}"#), "unchanged"),
    (config(process: #"{"user": {"uid": 0}, "args": ["/bin/sh"], "cwd": "/"}"#), "process.user.gid"),
    (config(process: #"{"user": {"uid": 0, "gid": 0, "umask": 512}, "args": ["/bin/sh"], "cwd": "/"}"#), "umask 01000"),
    (config(process: #"{"args": ["/bin/sh"], "cwd": "/", "noNewPrivileges": 1}"#), "process.noNewPrivileges"),
    (config(process: #"{"args": ["sh"], "cwd": "/"}"#), "absolute"),
    (config(process: #"{"args": [], "cwd": "/"}"#), "absolute"),
    (config(process: #"{"args": ["/bin/sh"], "env": ["NOEQUALS"], "cwd": "/"}"#), "NAME=value"),
    (config(process: #"{"args": ["/bin/sh"], "env": ["A=1", "NOEQUALS", "A=2"], "cwd": "/"}"#), "NAME=value"),
    (config(process: #"{"args": ["/bin/sh"], "env": ["=value"], "cwd": "/"}"#), "NAME=value"),
    (config(process: #"{"args": ["/bin/sh"], "cwd": "relative"}"#), "process.cwd"),
    (config(process: #"{"args": ["/bin/sh"], "cwd": "/a/../b"}"#), "process.cwd"),
    (config(linux: #"{"namespaces": [{"type": "mount"}], "devices": []}"#), "linux.devices"),
    // Path controls: lexical checks and value types.
    (config(linux: pathControls(#""readonlyPaths": ["proc/sys"]"#)), "linux.readonlyPaths[0]"),
    (config(linux: pathControls(#""readonlyPaths": ["/proc/sys", "/proc/../etc"]"#)), "linux.readonlyPaths[1]"),
    (config(linux: pathControls(#""maskedPaths": ["/proc/./kcore"]"#)), "linux.maskedPaths[0]"),
    (config(linux: pathControls(#""maskedPaths": ["/a\u0000b"]"#)), "linux.maskedPaths[0]"),
    (config(linux: pathControls(#""maskedPaths": "/proc/kcore""#)), "linux.maskedPaths"),
    (config(linux: pathControls(#""readonlyPaths": [1]"#)), "linux.readonlyPaths[0]"),
    (config(linux: pathControls(#""maskedPaths": null, "readonlyPath": []"#)), "linux.readonlyPath"),
    (config(version: "\"2.0.0\""), "ociVersion"),
    (config(hostname: "\"\""), "hostname"),
    (config(linux: #"{"namespaces": [{"type": "mount"}]}"#), "uts namespace"),
    (config(linux: #"{"namespaces": [{"type": "uts"}, {"type": "pid"}]}"#), "mount namespace"),
    (config(linux: #"{"namespaces": [{"type": "mount"}, {"type": "user"}]}"#), "user is not implemented"),
    (config(linux: #"{"namespaces": [{"type": "mount"}, {"type": "cgroup"}]}"#), "cgroup is not implemented"),
    (config(linux: #"{"namespaces": [{"type": "mount"}, {"type": "mount"}]}"#), "duplicate"),
    (config(linux: #"{"namespaces": [{"type": "mount"}, {"type": "uts"}], "rootfsPropagation": "shared"}"#), "rootfsPropagation"),
    (config(mounts: #"[{"destination": "/data", "type": "bind", "source": "/etc", "options": ["rbind"]}]"#), "bind"),
    (config(mounts: #"[{"destination": "/sys", "type": "sysfs", "source": "sysfs"}]"#), "sysfs"),
    (config(mounts: #"[{"destination": "/x", "type": "tmpfs", "options": ["ro"]}]"#), "ro"),
    (config(mounts: #"[{"destination": "/x", "type": "tmpfs", "options": ["uid=1000"]}]"#), "uid=1000"),
    (config(mounts: #"[{"destination": "/x", "type": "tmpfs", "options": ["mode=9"]}]"#), "mode=9"),
    (config(mounts: #"[{"destination": "/x", "type": "tmpfs", "options": [""]}]"#), "options"),
    (config(mounts: #"[{"destination": "/x", "type": "tmpfs", "source": "tmp\u0000fs"}]"#), "source must not contain NUL"),
    (config(mounts: #"[{"destination": "/x", "type": "tmpfs", "options": ["size="]}]"#), "size="),
    (config(mounts: #"[{"destination": "/dev", "type": "tmpfs", "options": ["nodev"]}]"#), "nodev"),
    (config(mounts: #"[{"destination": "/x/../../etc", "type": "tmpfs"}]"#), ".."),
    (config(mounts: #"[{"destination": "relative", "type": "tmpfs"}]"#), "absolute"),
    (config(mounts: #"[{"destination": "/", "type": "tmpfs"}]"#), "must not be /"),
    (config(mounts: #"[{"destination": "/other", "type": "proc"}]"#), "/proc"),
    (config(mounts: #"[{"destination": "/proc", "type": "proc"}]"#, linux: #"{"namespaces": [{"type": "mount"}, {"type": "uts"}]}"#), "pid namespace"),
    (#"{"ociVersion": "1.2.0"}"#, "missing required field"),
    (#"{"ociVersion": 1}"#, "invalid value"),
    ("not json", "invalid JSON"),
])
func rejectsUnsupportedConfiguration(_ json: String, _ reason: String) {
    do {
        _ = try plan(json)
        Issue.record("Expected rejection mentioning \(reason)")
    } catch let error as RuntimeError {
        #expect(error.description.contains(reason), "\(error.description)")
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test(arguments: ["abc", "a.b-c_d+e", "ABC123"])
func acceptsContainerIDs(_ id: String) throws {
    #expect(try ContainerID(id).rawValue == id)
}

@Test(arguments: ["", ".", "..", "a/b", "a b", "é", String(repeating: "x", count: 1025)])
func rejectsContainerIDs(_ id: String) {
    #expect(throws: RuntimeError.self) { try ContainerID(id) }
}

@Test func loadsBundleWithCanonicalAbsolutePaths() throws {
    try withTemporaryBundle { directory in
        try makeDirectory(directory.appending("rootfs"))
        try write(config(), to: directory.appending("config.json"))
        // A relative, non-canonical bundle path resolves to the canonical directory.
        let plan = try OCIRunPlan.load(bundle: directory.appending("rootfs").appending(".."))
        #expect(plan.bundle.isAbsolute)
        #expect(plan.bundle.lastComponent == directory.lastComponent)
        #expect(plan.rootfs == plan.bundle.appending("rootfs"))
    }
}

@Test func rejectsMissingRootfsAndConfiguration() throws {
    try withTemporaryBundle { directory in
        #expect(throws: RuntimeError.self) { try OCIRunPlan.load(bundle: directory) }
        try write(config(), to: directory.appending("config.json"))
        do {
            _ = try OCIRunPlan.load(bundle: directory)
            Issue.record("Expected missing rootfs to be rejected")
        } catch let error as RuntimeError {
            #expect(error.description.contains("root.path"))
        }
    }
}

@Test func rejectsRootfsResolvingToHostRoot() throws {
    try withTemporaryBundle { directory in
        try write(config(root: #"{"path": "/"}"#), to: directory.appending("config.json"))
        do {
            _ = try OCIRunPlan.load(bundle: directory)
            Issue.record("Expected host root to be rejected")
        } catch let error as RuntimeError {
            #expect(error.description.contains("host root"))
        }
    }
}

@Test func rejectsRootPathWithNULBeforeConstructingFilePath() throws {
    try withTemporaryBundle { directory in
        try makeDirectory(directory.appending("rootfs"))
        // Truncating at NUL would otherwise resolve to the existing rootfs.
        try write(config(root: #"{"path": "rootfs\u0000suffix"}"#), to: directory.appending("config.json"))
        do {
            _ = try OCIRunPlan.load(bundle: directory)
            Issue.record("Expected a NUL in root.path to be rejected")
        } catch let error as RuntimeError {
            #expect(error.description.contains("root.path must be non-empty and contain no NUL"))
        }
    }
}

@Test(arguments: [
    (["A=1", "B=2", "A=3"], ["B=2", "A=3"]),
    (["PATH=/bin", "X=", "PATH=/usr/bin", "X=y"], ["PATH=/usr/bin", "X=y"]),
    (["A=1=2", "B=x"], ["A=1=2", "B=x"]),
    ([], []),
])
func deduplicatesEnvironmentKeepingLastOccurrence(_ input: [String], _ expected: [String]) throws {
    #expect(try OCIRunPlan.environment(input) == expected)
    let process = #"{"args": ["/bin/true"], "cwd": "/", "env": [\#(input.map { "\"\($0)\"" }.joined(separator: ", "))]}"#
    #expect(try plan(config(process: process)).environment == expected)
}

@Test func environmentNamesCompareAsBytes() throws {
    // Canonically equivalent in Swift, but distinct byte sequences to Linux.
    let precomposed = "\u{E9}=1", decomposed = "e\u{301}=2"
    try #require("\u{E9}" == "e\u{301}", "Premise: Swift String equality merges these names")
    let result = try OCIRunPlan.environment([precomposed, decomposed])
    // Compare bytes: String equality cannot distinguish the two entries.
    #expect(result.map { Array($0.utf8) } == [Array(precomposed.utf8), Array(decomposed.utf8)])
}

@Test(arguments: [["A=1", "NOEQUALS", "A=2"], ["=x", "A=1"], ["A=1", "B=bad\0value", "B=ok"]])
func validatesEveryEnvironmentEntryBeforeDeduplicating(_ input: [String]) {
    #expect(throws: RuntimeError.self) { try OCIRunPlan.environment(input) }
}

@Test(arguments: [
    ("/" + Array(repeating: "a", count: 128).joined(separator: "/"), nil),
    ("/" + Array(repeating: "a", count: 129).joined(separator: "/"), "components"),
    ("/" + String(repeating: "a", count: 4094), nil),
    ("/" + String(repeating: "a", count: 4095), "bytes"),
])
func boundsContainerPaths(_ path: String, _ rejection: String?) throws {
    let mounts = #"[{"destination": "\#(path)", "type": "tmpfs"}]"#
    let process = #"{"args": ["/bin/true"], "cwd": "\#(path)"}"#
    for json in [config(mounts: mounts), config(process: process)] {
        do {
            _ = try plan(json)
            #expect(rejection == nil, "Expected \(rejection ?? "") rejection")
        } catch let error as RuntimeError {
            let reason = try #require(rejection, "Unexpected rejection: \(error)")
            #expect(error.description.contains(reason), "\(error.description)")
        }
    }
}

#if !os(Linux)
@Test func ociRunReportsUnsupportedPlatform() throws {
    #expect(throws: RuntimeError.self) { try plan(config()).run() }
}
#endif

private func withTemporaryBundle(_ body: (FilePath) throws -> Void) throws {
    var template = Array("/tmp/swift-runtime-bundle-XXXXXX".utf8CString)
    // mkdtemp fills in the template in place; the buffer outlives the call.
    let created = template.withUnsafeMutableBufferPointer { buffer in
        unsafe mkdtemp(buffer.baseAddress!) != nil
    }
    try #require(created)
    let directory = template.withUnsafeBufferPointer { buffer in
        unsafe FilePath(platformString: buffer.baseAddress!)
    }
    defer {
        try? removeFile(directory.appending("config.json"))
        _ = unsafe directory.appending("rootfs").withPlatformString { unsafe rmdir($0) }
        _ = unsafe directory.withPlatformString { unsafe rmdir($0) }
    }
    try body(directory)
}

private func makeDirectory(_ path: FilePath) throws {
    let result = unsafe path.withPlatformString { unsafe mkdir($0, 0o755) }
    try #require(result == 0)
}

private func write(_ text: String, to path: FilePath) throws {
    let descriptor = try FileDescriptor.open(path, .writeOnly, options: [.create, .truncate], permissions: [.ownerReadWrite])
    defer { try? descriptor.close() }
    _ = try descriptor.writeAll(text.utf8)
}

private func removeFile(_ path: FilePath) throws {
    let result = unsafe path.withPlatformString { unsafe unlink($0) }
    if result != 0 { throw Errno(rawValue: errno) }
}
