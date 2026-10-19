#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SystemPackage
import Testing
@testable import ContainerRuntime

private let box = try! ContainerID("box")
private let bootID = "0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"

// MARK: Transitions

@Test(arguments: [
    (LifecycleOperation.start, ContainerStatus.created, LifecycleOperation.Action.proceed),
    (.kill, .created, .proceed),
    (.kill, .running, .proceed),
    (.kill, .paused, .proceed),
    (.pause, .running, .proceed),
    (.pause, .created, .proceed),
    (.resume, .paused, .proceed),
    (.update, .created, .proceed),
    (.update, .running, .proceed),
    (.update, .paused, .proceed),
    (.delete(force: true), .paused, .killThenDestroy),
    (.delete(force: false), .stopped, .destroy),
    (.delete(force: true), .stopped, .destroy),
    // runc deletes a created container without --force by killing its init.
    (.delete(force: false), .created, .killThenDestroy),
    (.delete(force: true), .created, .killThenDestroy),
    (.delete(force: true), .running, .killThenDestroy),
    (.delete(force: true), .creating, .killThenDestroy),
])
func permitsRuncTransitions(_ operation: LifecycleOperation, _ status: ContainerStatus, _ action: LifecycleOperation.Action) throws {
    #expect(try operation.action(for: status, id: box) == action)
}

@Test(arguments: [
    (LifecycleOperation.start, ContainerStatus.creating, "cannot start container box in the creating state"),
    (.start, .running, "cannot start container box in the running state"),
    (.start, .stopped, "cannot start container box in the stopped state"),
    (.kill, .creating, "cannot kill container box in the creating state"),
    (.kill, .stopped, "cannot kill container box in the stopped state"),
    (.pause, .paused, "cannot pause container box in the paused state"),
    (.pause, .stopped, "cannot pause container box in the stopped state"),
    (.resume, .running, "cannot resume container box in the running state"),
    (.update, .stopped, "cannot update container box in the stopped state"),
    (.start, .paused, "cannot start container box in the paused state"),
    (.delete(force: false), .paused, "cannot delete container box in the paused state (use --force)"),
    (.delete(force: false), .running, "cannot delete container box in the running state (use --force)"),
    (.delete(force: false), .creating, "cannot delete container box in the creating state (use --force)"),
])
func rejectsInvalidTransitionsWithStableMessages(_ operation: LifecycleOperation, _ status: ContainerStatus, _ message: String) {
    do {
        _ = try operation.action(for: status, id: box)
        Issue.record("Expected \(operation) to be rejected in \(status)")
    } catch let error as LifecycleError {
        #expect(error.description == message)
    } catch {
        Issue.record("Unexpected error \(error)")
    }
}

@Test func describesMissingAndDuplicateContainers() {
    #expect(LifecycleError.notFound(box).description == "container box does not exist")
    #expect(LifecycleError.alreadyExists(box).description == "container box already exists")
}

@Test(arguments: [
    // hasInit, alive, creatorActive, socket -> status
    (false, false, true, false, ContainerStatus.creating),
    (false, false, false, false, .stopped),
    (true, false, false, true, .stopped),
    (true, false, false, false, .stopped),
    (true, true, false, true, .created),
    (true, true, false, false, .running),
])
func derivesStatusFromLiveFacts(_ hasInit: Bool, _ alive: Bool, _ creator: Bool, _ socket: Bool, _ expected: ContainerStatus) {
    #expect(ContainerStatus.derive(hasInit: hasInit, initAlive: alive, creatorActive: creator, startSocketPresent: socket) == expected)
}

@Test func frozenStateRequiresALiveInit() {
    #expect(ContainerStatus.derive(hasInit: true, initAlive: true, creatorActive: false, startSocketPresent: false, frozen: true) == .paused)
    #expect(ContainerStatus.derive(hasInit: true, initAlive: true, creatorActive: false, startSocketPresent: true, frozen: true) == .paused)
    #expect(ContainerStatus.derive(hasInit: true, initAlive: false, creatorActive: false, startSocketPresent: false, frozen: true) == .stopped)
}

// MARK: Persisted record

private func record(initProcess: InitIdentity? = InitIdentity(pid: 4242, startTime: 987_654, bootID: bootID)) -> ContainerRecord {
    var record = ContainerRecord(
        id: box,
        plan: try! OCIRunPlan(
            OCIConfiguration.decode(Array(#"""
            {"ociVersion": "1.0.2", "root": {"path": "rootfs"}, "process": {"args": ["/bin/true"], "cwd": "/"},
             "linux": {"namespaces": [{"type": "mount"}, {"type": "pid"}]}, "annotations": {"org.example/key": "value"}}
            """#.utf8)),
            bundle: FilePath("/srv/bundle"), rootfs: FilePath("/srv/bundle/rootfs")
        ),
        created: Date(timeIntervalSince1970: 1_792_108_800)
    )
    record.initProcess = initProcess
    return record
}

@Test func recordCapturesPlanAndRoundTrips() throws {
    let original = record()
    #expect(original.ociVersion == "1.0.2")
    #expect(original.bundle == "/srv/bundle")
    #expect(original.rootfs == "/srv/bundle/rootfs")
    #expect(original.annotations == ["org.example/key": "value"])
    #expect(original.pidNamespace)
    let decoded = try ContainerRecord.decode(try original.encoded(), expectedID: box)
    #expect(decoded == original)
    // Paths are written without escaped slashes and keys are sorted.
    let text = String(decoding: try original.encoded(), as: UTF8.self)
    #expect(text.contains(#""bundle":"/srv/bundle""#))
    #expect(text.hasPrefix(#"{"annotations""#))
}

@Test func recordWithoutInitRoundTrips() throws {
    let original = record(initProcess: nil)
    #expect(try ContainerRecord.decode(try original.encoded(), expectedID: box) == original)
}

@Test func recordWithCgroupRoundTrips() throws {
    var original = record()
    original.cgroup = CgroupIdentity(path: "/swift-container-runtime/box", inode: 4242, bootID: bootID, created: true)
    #expect(try ContainerRecord.decode(try original.encoded(), expectedID: box) == original)
    let text = String(decoding: try original.encoded(), as: UTF8.self)
    #expect(text.contains(#""cgroup":{"bootID":"0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0","created":true,"inode":4242,"path":"/swift-container-runtime/box"}"#))
}

/// Records written before cgroup support have no `cgroup` key; they decode
/// as containers without a cgroup to clean up.
@Test func recordFromBeforeCgroupsDecodes() throws {
    let text = String(decoding: try record().encoded(), as: UTF8.self)
    #expect(!text.contains("cgroup"))
    #expect(try ContainerRecord.decode(Array(text.utf8), expectedID: box).cgroup == nil)
}

private func mutated(_ change: (inout ContainerRecord) -> Void) throws -> [UInt8] {
    var value = record()
    change(&value)
    return try value.encoded()
}

@Test(arguments: [
    ("format", { @Sendable (record: inout ContainerRecord) in record.format = 2 }),
    ("names container other", { @Sendable (record: inout ContainerRecord) in record.id = "other" }),
    ("absolute", { @Sendable (record: inout ContainerRecord) in record.bundle = "relative/bundle" }),
    ("absolute", { @Sendable (record: inout ContainerRecord) in record.rootfs = "" }),
    ("init PID 1", { @Sendable (record: inout ContainerRecord) in record.initProcess?.pid = 1 }),
    ("init PID 0", { @Sendable (record: inout ContainerRecord) in record.initProcess?.pid = 0 }),
    ("init PID -5", { @Sendable (record: inout ContainerRecord) in record.initProcess?.pid = -5 }),
    ("start time", { @Sendable (record: inout ContainerRecord) in record.initProcess?.startTime = 0 }),
    ("boot ID", { @Sendable (record: inout ContainerRecord) in record.initProcess?.bootID = "../../etc" }),
    ("invalid cgroup", { @Sendable (record: inout ContainerRecord) in
        record.cgroup = CgroupIdentity(path: "/", inode: 7, bootID: bootID, created: true)
    }),
    ("invalid cgroup", { @Sendable (record: inout ContainerRecord) in
        record.cgroup = CgroupIdentity(path: "/a/../../etc", inode: 7, bootID: bootID, created: true)
    }),
    ("invalid cgroup", { @Sendable (record: inout ContainerRecord) in
        record.cgroup = CgroupIdentity(path: "relative/box", inode: 7, bootID: bootID, created: true)
    }),
    ("invalid cgroup", { @Sendable (record: inout ContainerRecord) in
        record.cgroup = CgroupIdentity(path: "/swift-container-runtime/box", inode: 0, bootID: bootID, created: true)
    }),
    ("invalid cgroup", { @Sendable (record: inout ContainerRecord) in
        record.cgroup = CgroupIdentity(path: "/swift-container-runtime/box", inode: 7, bootID: "../../etc", created: true)
    }),
] as [(String, @Sendable (inout ContainerRecord) -> Void)])
func rejectsMalformedRecords(_ reason: String, _ change: @Sendable (inout ContainerRecord) -> Void) throws {
    let bytes = try mutated(change)
    do {
        _ = try ContainerRecord.decode(bytes, expectedID: box)
        Issue.record("Expected a corrupt-state error mentioning \(reason)")
    } catch let error as RuntimeError {
        #expect(error.description.contains("state of container box is corrupt"))
        #expect(error.description.contains(reason), "\(error.description)")
    }
}

@Test(arguments: ["", "not json", #"{"format": 1}"#, "[]"])
func rejectsUndecodableRecords(_ text: String) {
    #expect(throws: RuntimeError.self) { try ContainerRecord.decode(Array(text.utf8), expectedID: box) }
}

@Test(arguments: [(bootID, true), ("0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0", false), ("", false), (bootID + "0", false)])
func validatesBootIDs(_ value: String, _ valid: Bool) {
    #expect(InitIdentity.isValidBootID(value) == valid)
}

// MARK: Reports

private struct StateDocument: Decodable, Equatable {
    var ociVersion: String
    var id: String
    var pid: Int32
    var status: String
    var bundle: String
    var rootfs: String
    var created: String
    var annotations: [String: String]?
    var owner: String?
}

@Test func stateJSONFollowsOCIStateShape() throws {
    let running = ContainerStateReport(record: record(), id: box, status: .running, owner: "root")
    let document = try JSONDecoder().decode(StateDocument.self, from: Data(try running.stateJSON().utf8))
    #expect(document == StateDocument(
        ociVersion: "1.0.2", id: "box", pid: 4242, status: "running", bundle: "/srv/bundle",
        rootfs: "/srv/bundle/rootfs", created: "2026-10-16T00:00:00.000Z", annotations: ["org.example/key": "value"], owner: nil
    ))
}

@Test(arguments: [ContainerStatus.stopped, .creating])
func reportsPIDZeroWithoutLiveInit(_ status: ContainerStatus) throws {
    let report = ContainerStateReport(record: record(), id: box, status: status, owner: "root")
    #expect(report.pid == 0)
    let document = try JSONDecoder().decode(StateDocument.self, from: Data(try report.stateJSON().utf8))
    #expect(document.pid == 0)
    #expect(document.status == status.rawValue)
}

@Test func omitsEmptyAnnotations() throws {
    var plain = record()
    plain.annotations = [:]
    let json = try ContainerStateReport(record: plain, id: box, status: .created, owner: "").stateJSON()
    #expect(!json.contains("annotations"))
    #expect(try JSONDecoder().decode(StateDocument.self, from: Data(json.utf8)).pid == 4242)
}

@Test func listJSONIsOneArrayWithOwners() throws {
    let reports = [
        ContainerStateReport(record: record(), id: box, status: .created, owner: "root"),
        ContainerStateReport(record: nil, id: try ContainerID("partial"), status: .stopped, owner: "#1000"),
    ]
    let json = try ContainerStateReport.listJSON(reports)
    #expect(!json.contains("\n"))
    let documents = try JSONDecoder().decode([StateDocument].self, from: Data(json.utf8))
    #expect(documents.map(\.id) == ["box", "partial"])
    #expect(documents.map(\.owner) == ["root", "#1000"])
    #expect(documents[1].bundle == "")
    #expect(try ContainerStateReport.listJSON([]) == "null")
}

@Test func tableMatchesRuncLayout() {
    let report = ContainerStateReport(record: record(), id: box, status: .running, owner: "root")
    func spaces(_ count: Int) -> String { String(repeating: " ", count: count) }
    // Widths: max(12, widest cell + 3); the last column is not padded.
    let expected = "ID" + spaces(10) + "PID" + spaces(9) + "STATUS" + spaces(6) + "BUNDLE" + spaces(8)
        + "CREATED" + spaces(20) + "OWNER\n"
        + "box" + spaces(9) + "4242" + spaces(8) + "running" + spaces(5) + "/srv/bundle" + spaces(3)
        + "2026-10-16T00:00:00.000Z" + spaces(3) + "root\n"
    #expect(ContainerStateReport.table([report]) == expected)
    let empty = "ID" + spaces(10) + "PID" + spaces(9) + "STATUS" + spaces(6) + "BUNDLE" + spaces(6) + "CREATED" + spaces(5) + "OWNER\n"
    #expect(ContainerStateReport.table([]) == empty)
}

// MARK: Parsing and formatting

@Test func parsesProcStatWithHostileCommandNames() throws {
    // Field 22 (start time) follows a command name containing ") " and spaces.
    let fields = (3...52).map { $0 == 3 ? "S" : $0 == 22 ? "123456789" : "0" }
    let line = "4242 (evil) name (x) " + fields.joined(separator: " ") + "\n"
    let stat = try #require(ProcessStat(parsing: Array(line.utf8)))
    #expect(stat.state == UInt8(ascii: "S"))
    #expect(stat.startTime == 123_456_789)
    #expect(!stat.hasExited)
    let zombie = try #require(ProcessStat(parsing: Array(line.replacing(") S ", with: ") Z ").utf8)))
    #expect(zombie.hasExited)
}

@Test(arguments: ["", "4242 no-parens S 1", "4242 (short) S 1 2 3", "4242 (x) S" + String(repeating: " 1", count: 18) + " notanumber"])
func rejectsMalformedProcStat(_ line: String) {
    #expect(ProcessStat(parsing: Array(line.utf8)) == nil)
}

@Test(arguments: [
    ("TERM", Int32(15)), ("SIGTERM", 15), ("sigkill", 9), ("Kill", 9), ("USR1", 10), ("SIGUSR2", 12),
    ("CHLD", 17), ("WINCH", 28), ("9", 9), ("1", 1), ("64", 64), ("0", 0), ("+9", 9),
])
func parsesLinuxSignals(_ text: String, _ number: Int32) throws {
    #expect(try SignalName.parse(text) == number)
}

@Test(arguments: ["", "65", "-9", "SIG", "NOPE", "SIGTERMX", "TERM ", "ＴＥＲＭ"])
func rejectsUnknownSignals(_ text: String) {
    #expect(throws: RuntimeError.self) { try SignalName.parse(text) }
}

@Test(arguments: ["", "bad\0root"])
func lifecycleRejectsInvalidRoots(_ root: String) {
    #expect(throws: RuntimeError.self) { try ContainerLifecycle(root: root) }
}

@Test func lifecycleDefaultsToRuntimeDirectory() throws {
    #expect(try ContainerLifecycle().root == FilePath(ContainerLifecycle.defaultRoot))
    #expect(ContainerLifecycle.defaultRoot(effectiveUID: 0, runtimeDirectory: "/run/user/0") == "/run/swift-container-runtime")
    #expect(ContainerLifecycle.defaultRoot(effectiveUID: 1000, runtimeDirectory: nil) == "/run/swift-container-runtime")
    #expect(ContainerLifecycle.defaultRoot(effectiveUID: 1000, runtimeDirectory: "relative") == "/run/swift-container-runtime")
}

/// Like runc, a rootless caller keeps its state below $XDG_RUNTIME_DIR.
@Test func rootlessLifecycleDefaultsToXDGRuntimeDirectory() {
    #expect(ContainerLifecycle.defaultRoot(effectiveUID: 1000, runtimeDirectory: "/run/user/1000") == "/run/user/1000/swift-container-runtime")
    #expect(ContainerLifecycle.defaultRoot(effectiveUID: 1000, runtimeDirectory: "/run/user/1000/") == "/run/user/1000/swift-container-runtime")
}

/// Lifecycle commands on a missing root report the missing container and
/// never create state; off Linux this is also what every command meets.
@Test func lifecycleOnMissingRootNeverCreatesState() throws {
    let root = "/nonexistent-swift-container-runtime-root/state"
    let lifecycle = try ContainerLifecycle(root: root)
    #expect(throws: LifecycleError.notFound(box)) { try lifecycle.state(id: box) }
    #expect(throws: LifecycleError.notFound(box)) { try lifecycle.start(id: box) }
    #expect(throws: LifecycleError.notFound(box)) { try lifecycle.kill(id: box, signal: 15) }
    #expect(throws: RuntimeError.self) { try lifecycle.list() }
    _ = try? lifecycle.delete(id: box, force: true)
    #expect(!FileManager.default.fileExists(atPath: "/nonexistent-swift-container-runtime-root"))
}

@Test func rawResourceSettingsSurviveStateRoundTrip() throws {
    let config = try OCIConfiguration.decode(Array(#"""
    {"ociVersion":"1.0.2","root":{"path":"rootfs"},"process":{"args":["/bin/true"],"cwd":"/"},
     "linux":{"namespaces":[{"type":"mount"}],"resources":{
       "memory":{"limit":8192,"swap":16384},"pids":{"limit":5},
       "cpu":{"shares":512,"quota":50000,"period":200000,"burst":0,"cpus":"1"}}}}
    """#.utf8))
    let plan = try OCIRunPlan(config, bundle: FilePath("/bundle"), rootfs: FilePath("/bundle/rootfs"))
    let original = ContainerRecord(id: box, plan: plan)
    let decoded = try ContainerRecord.decode(original.encoded(), expectedID: box)
    let saved = try #require(decoded.resourceConfiguration)
    #expect(saved.cpu?.quota == 50000)
    #expect(saved.cpu?.period == 200000)
    #expect(saved.cpu?.shares == 512)
    #expect(saved.cpu?.burst == 0)
    #expect(saved.memory?.swap == 16384)
    #expect(try CgroupPlan.converted(saved) == plan.cgroup.resources)
}

@Test func legacyRecordsRemainDistinctFromEmptyResourceSettings() throws {
    var expected = record()
    #expect(expected.resourceConfiguration != nil)
    expected.resourceConfiguration = nil
    let legacy = try expected.encoded()
    #expect(!String(decoding: legacy, as: UTF8.self).contains(#""resourceConfiguration""#))
    #expect(try ContainerRecord.decode(legacy, expectedID: box) == expected)
}

@Test func execAdmissionWaitsForResumeOnlyWhenIgnoringPaused() {
    #expect(LifecycleOperation.execAdmission(status: .running, ignorePaused: false) == .proceed)
    #expect(LifecycleOperation.execAdmission(status: .created, ignorePaused: true) == .proceed)
    #expect(LifecycleOperation.execAdmission(status: .paused, ignorePaused: true) == .waitForResume)
    #expect(LifecycleOperation.execAdmission(status: .paused, ignorePaused: false)
        == .reject("cannot exec in a paused container (use --ignore-paused to wait for resume)"))
    #expect(LifecycleOperation.execAdmission(status: .stopped, ignorePaused: true) == .reject("cannot exec in a stopped container"))
    #expect(LifecycleOperation.execAdmission(status: .creating, ignorePaused: true) == .reject("cannot exec in a creating container"))
}

@Test func inheritedMountCleanupAuthorityRoundTrips() throws {
    var original = record()
    let json = #"{"originalMountID":123,"root":{"device":1,"inode":2},"namespace":{"device":3,"inode":4},"bootID":"\#(bootID)"}"#
    original.sharedRootfsMount = try JSONDecoder().decode(SharedRootfsMount.self, from: Data(json.utf8))
    #expect(try ContainerRecord.decode(try original.encoded(), expectedID: box) == original)
    original.rootfs = "/"
    #expect(throws: RuntimeError.self) { try ContainerRecord.decode(try original.encoded(), expectedID: box) }
}
