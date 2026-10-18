import Foundation
import SystemPackage
import Testing
@testable import ContainerRuntime

private func oomProcess(_ field: String) throws -> OCIProcessPlan {
    try OCIProcessPlan(OCIConfiguration.decodeProcess(Array("{\"args\":[\"/bin/true\"],\"cwd\":\"/\"\(field)}".utf8)))
}

@Test(arguments: [-1000, -300, 0, 300, 1000])
func oomScoreAcceptsKernelRange(_ value: Int32) throws {
    #expect(try oomProcess(",\"oomScoreAdj\":\(value)").oomScoreAdjustment == value)
}

@Test func oomScoreAbsenceAndNullPreserveInheritance() throws {
    #expect(try oomProcess("").oomScoreAdjustment == nil)
    #expect(try oomProcess(",\"oomScoreAdj\":null").oomScoreAdjustment == nil)
}

@Test(arguments: ["-1001", "1001", "1.5", "true", "\"0\"", "9223372036854775808"])
func oomScoreRejectsInvalidValues(_ value: String) {
    #expect(throws: RuntimeError.self) { try oomProcess(",\"oomScoreAdj\":\(value)") }
}

@Test func oomScorePersistsIndependentlyOfBundleAndProcessOverrides() throws {
    let json = #"{"ociVersion":"1.0.2","root":{"path":"rootfs"},"process":{"args":["/bin/true"],"cwd":"/","oomScoreAdj":321},"mounts":[],"linux":{"namespaces":[{"type":"mount"}]}}"#
    let configuration = try OCIConfiguration.decode(Array(json.utf8))
    let plan = try OCIRunPlan(configuration, bundle: FilePath("/bundle"), rootfs: FilePath("/rootfs"))
    let id = try ContainerID("oom-state")
    var record = ContainerRecord(id: id, plan: plan)
    #expect(try ContainerRecord.decode(record.encoded(), expectedID: id).oomScoreAdjustment == 321)
    record.oomScoreAdjustment = 1001
    #expect(throws: RuntimeError.self) { try ContainerRecord.decode(record.encoded(), expectedID: id) }
}
