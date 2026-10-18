import Foundation
import Testing
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
