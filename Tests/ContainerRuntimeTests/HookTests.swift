import Foundation
import SystemPackage
import Testing
@testable import ContainerRuntime

private func hookPlan(_ hooks: String) throws -> OCIRunPlan {
    let json = #"{"ociVersion":"1.0.2","root":{"path":"rootfs"},"process":{"args":["/bin/true"],"cwd":"/"},"mounts":[],"linux":{"namespaces":[{"type":"mount"}]},"hooks":"#
        + hooks + "}"
    return try OCIRunPlan(OCIConfiguration.decode(Array(json.utf8)), bundle: FilePath("/bundle"), rootfs: FilePath("/rootfs"))
}

@Test func hooksDecodeEveryPhaseInOrder() throws {
    let plan = try hookPlan(#"{"createRuntime": [{"path": "/hook", "args": ["hook", "a"], "env": ["X=1"], "timeout": 5}], "poststop": [{"path": "/stop"}]}"#)
    let hook = try #require(plan.hooks.createRuntime.first)
    #expect(hook.argv == ["hook", "a"])
    #expect(hook.env == ["X=1"])
    #expect(hook.duration == .seconds(5))
    // Without args, argv is just the path, as Go's exec runs runc's hooks.
    #expect(plan.hooks.poststop.first?.argv == ["/stop"])
    #expect(ContainerHooks.Phase.allCases.map(\.rawValue) == ["prestart", "createRuntime", "createContainer", "startContainer", "poststart", "poststop"])
}

@Test func hooksPersistWithContainerState() throws {
    let plan = try hookPlan(#"{"poststart": [{"path": "/start"}], "poststop": [{"path": "/stop", "args": ["stop"]}]}"#)
    let id = try ContainerID("hook-state")
    let decoded = try ContainerRecord.decode(ContainerRecord(id: id, plan: plan).encoded(), expectedID: id)
    #expect(decoded.hooks == plan.hooks)
    // A container without hooks records none, so legacy and empty agree.
    #expect(ContainerRecord(id: id, plan: try hookPlan("{}")).hooks == nil)
}

@Test func hookStateMatchesTheOCIStateShape() throws {
    let state = HookState(ociVersion: "1.0.2", id: "box", status: .creating, pid: 42, bundle: "/b", annotations: ["k": "v"])
    let object = try #require(JSONSerialization.jsonObject(with: Data(try state.encoded())) as? [String: Any])
    #expect(object["status"] as? String == "creating")
    #expect(object["pid"] as? Int == 42)
    #expect(object["bundle"] as? String == "/b")
    let stopped = HookState(ociVersion: "1.0.2", id: "box", status: .stopped, pid: nil, bundle: "/b", annotations: [:])
    let text = String(decoding: try stopped.encoded(), as: UTF8.self)
    #expect(!text.contains("pid") && !text.contains("annotations"))
}

@Test(arguments: [
    HookOutcome.exited(3), .signaled(9), .timedOut(seconds: 2), .spawnFailed(.noSuchFileOrDirectory),
])
func containerHookFailuresSurviveTheLaunchRecord(_ outcome: HookOutcome) {
    let failure = outcome.failure(at: .startContainerHook, index: 7)
    let unpacked = HookOutcome.unpack(detail: failure.detail, error: failure.error)
    #expect(unpacked.index == 7)
    #expect(unpacked.outcome == outcome)
}

@Test func hookFailureMessagesFollowRunc() {
    #expect(ContainerHooks.failureMessage(.createRuntime, 1, .exited(3), output: Array("boom\n".utf8))
        == "error running createRuntime hook #1: exit status 3, output: boom")
    #expect(ContainerHooks.failureMessage(.poststart, 0, .signaled(9)) == "error running poststart hook #0: signal: killed")
    #expect(ContainerHooks.failureMessage(.startContainer, 0, .timedOut(seconds: 2)) == "error running startContainer hook #0: timeout after 2s")
}
