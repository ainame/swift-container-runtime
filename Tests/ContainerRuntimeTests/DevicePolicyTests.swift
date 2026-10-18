import Foundation
import Testing
@testable import ContainerRuntime

@Test func deviceRulesMergeAccessAndResetInOrder() throws {
    let policy = try DevicePolicy([
        .init(allow: true, type: "c", major: 200, minor: 1, access: "r"),
        .init(allow: true, type: "c", major: 200, minor: 1, access: "w"),
        .init(allow: false, type: "c", major: 200, minor: 1, access: "w"),
    ])
    #expect(!policy.defaultAllow)
    #expect(policy.exceptions.first { $0.device.major == 200 }?.access == 2)
    let reset = try DevicePolicy([
        .init(allow: true, type: "c", major: 200, access: "rwm"),
        .init(allow: true, access: "rwm"),
        .init(allow: false, type: "c", major: 201, minor: 1, access: "r"),
    ])
    #expect(reset.defaultAllow)
    #expect(!reset.exceptions.contains { $0.device.major == 200 })
    #expect(reset.exceptions.first { $0.device.major == 201 }?.access == 2)
}

@Test func deviceRulesRejectPartialWildcardHoles() {
    #expect(throws: RuntimeError.self) {
        try DevicePolicy([
            .init(allow: true, type: "c", major: 200, access: "rwm"),
            .init(allow: false, type: "c", major: 200, minor: 1, access: "r"),
        ])
    }
}

@Test func deviceRulesKeepRuncDefaultNodesAfterDenyAll() throws {
    let policy = try DevicePolicy([.init(allow: false, access: "rwm")])
    #expect(!policy.defaultAllow)
    #expect(policy.exceptions.contains { $0.device.type == 2 && $0.device.major == 1 && $0.device.minor == 3 && $0.access == 7 })
    #expect(policy.exceptions.contains { $0.device.type == 1 && $0.device.major == nil && $0.device.minor == nil && $0.access == 1 })
}

@Test(arguments: [
    #"[{"allow":true,"type":"x","access":"rwm"}]"#,
    #"[{"allow":true,"major":-2,"access":"rwm"}]"#,
    #"[{"allow":true,"minor":4294967296,"access":"rwm"}]"#,
    #"[{"allow":false,"access":""}]"#,
    #"[{"allow":false,"access":"x"}]"#,
    #"[{"allow":true,"access":"rwm","unknown":1}]"#,
])
func rejectsMalformedDevicePolicy(_ json: String) {
    #expect(throws: (any Error).self) {
        let rules = try JSONDecoder().decode([OCIConfiguration.DeviceRule].self, from: Data(json.utf8))
        _ = try DevicePolicy(rules)
    }
}

@Test func resourceUpdatesRetainDevicePolicyAndRejectDevicePatches() throws {
    var previous = OCIConfiguration.Resources()
    previous.devices = [.init(allow: false, access: "rwm")]
    let merged = ResourceUpdate(pidsLimit: 10).merged(with: previous)
    #expect(merged.devices == previous.devices)
    #expect(try CgroupPlan.converted(merged).devicePolicy != nil)
    #expect(throws: RuntimeError.self) { try ResourceUpdate(json: Array(#"{"devices":[]}"#.utf8)) }
}
