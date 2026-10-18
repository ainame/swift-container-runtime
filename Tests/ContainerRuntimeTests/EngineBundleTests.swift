import Foundation
import Testing
import SystemPackage
@testable import ContainerRuntime

private func engineFixture(_ name: String) throws -> Data {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/engine-baseline/\(name)")
    return try Data(contentsOf: path)
}

@Test func capturedEngineCreateKeepsUnsupportedSecurityExplicit() throws {
    let data = try engineFixture("create.config.json")
    do {
        _ = try JSONDecoder().decode(OCIConfiguration.self, from: data)
        Issue.record("Device restrictions must be applied or rejected")
    } catch {
        #expect(String(describing: error).contains("linux.resources.devices"))
    }
}

@Test func capturedEngineExecProcessIsSupported() throws {
    let data = try engineFixture("exec.process.json")
    let process = try JSONDecoder().decode(OCIConfiguration.Process.self, from: data)
    let plan = try OCIProcessPlan(process)
    #expect(plan.arguments == ["/bin/busybox", "sleep", "300"])
    #expect(plan.security.noNewPrivileges)
}

@Test func capturedEngineMountsPlanWithoutUnsupportedDevicePolicy() throws {
    // A planning projection only: the original live bundle must keep failing
    // until device restrictions are enforced. Never replay this as live evidence.
    var object = try #require(JSONSerialization.jsonObject(with: engineFixture("create.config.json")) as? [String: Any])
    var linux = try #require(object["linux"] as? [String: Any])
    var resources = try #require(linux["resources"] as? [String: Any])
    resources["devices"] = nil
    linux["resources"] = resources
    object["linux"] = linux
    let config = try JSONDecoder().decode(OCIConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
    let plan = try OCIRunPlan(config, bundle: FilePath("/bundle"), rootfs: FilePath("/rootfs"))
    #expect(plan.mounts.contains { $0.type == .sysfs && $0.flags.contains(.readonly) })
    #expect(plan.mounts.contains { $0.type == .mqueue && $0.destinationPath == "/dev/mqueue" })
    #expect(plan.mounts.contains { $0.type == .tmpfs && $0.destinationPath == "/dev/shm" })
}
