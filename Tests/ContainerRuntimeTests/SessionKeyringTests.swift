import Foundation
import SystemPackage
import Testing
@testable import ContainerRuntime

@Test func keyringSetupPreparesNamesWithoutChangingTheCaller() throws {
    let id = try ContainerID("keyring-test")
    let setup = SessionKeyringSetup(id: id, disabled: false, isExec: false)
    #expect(setup.name == Array("_ses.keyring-test".utf8CString))
    #expect(!setup.isExec)
    let inherited = SessionKeyringSetup(id: id, disabled: true, isExec: true)
    #expect(inherited.name == nil)
    #expect(inherited.apply() == nil)
}

@Test(arguments: [false, true])
func keyringPolicyPersistsAndOldRecordsRemainReadable(_ disabled: Bool) throws {
    let json = #"{"ociVersion":"1.0.2","root":{"path":"rootfs"},"process":{"args":["/bin/true"],"cwd":"/"},"mounts":[],"linux":{"namespaces":[{"type":"mount"}]}}"#
    let configuration = try OCIConfiguration.decode(Array(json.utf8))
    let plan = try OCIRunPlan(configuration, bundle: FilePath("/bundle"), rootfs: FilePath("/rootfs"))
    let id = try ContainerID("keyring-state")
    let record = ContainerRecord(id: id, plan: plan, noNewKeyring: disabled)
    #expect(try ContainerRecord.decode(record.encoded(), expectedID: id).noNewKeyring == disabled)
    // Legacy records had inherited sessions; exec must retain that behavior.
    var object = try #require(JSONSerialization.jsonObject(with: Data(record.encoded())) as? [String: Any])
    object.removeValue(forKey: "noNewKeyring")
    let legacy = try ContainerRecord.decode(Array(JSONSerialization.data(withJSONObject: object)), expectedID: id)
    #expect(legacy.noNewKeyring == nil)
}
