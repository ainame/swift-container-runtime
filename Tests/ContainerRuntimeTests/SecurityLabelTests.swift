import SystemPackage
import Testing
@testable import ContainerRuntime

private func labelProcess(_ fields: String) throws -> OCIProcessPlan {
    try OCIProcessPlan(OCIConfiguration.decodeProcess(Array("{\"args\":[\"/bin/true\"],\"cwd\":\"/\"\(fields)}".utf8)))
}

private func labelPlan(process fields: String, linux: String = "") throws -> OCIRunPlan {
    let json = #"{"ociVersion":"1.0.2","root":{"path":"rootfs"},"process":{"args":["/bin/true"],"cwd":"/""#
        + fields + #"},"mounts":[],"linux":{"namespaces":[{"type":"mount"}]"# + linux + "}}"
    return try OCIRunPlan(OCIConfiguration.decode(Array(json.utf8)), bundle: FilePath("/bundle"), rootfs: FilePath("/rootfs"))
}

@Test func securityLabelsDecodeFromProcess() throws {
    let labels = try labelProcess(#","apparmorProfile":"docker-default","selinuxLabel":"system_u:system_r:container_t:s0""#).securityLabels
    #expect(labels == SecurityLabels(appArmorProfile: "docker-default", selinuxLabel: "system_u:system_r:container_t:s0"))
}

@Test func emptySecurityLabelsMeanUnset() throws {
    #expect(try labelProcess(#","apparmorProfile":"","selinuxLabel":"""#).securityLabels == SecurityLabels())
    #expect(try labelProcess("").securityLabels == SecurityLabels())
    // An empty mount label requests nothing, as Docker writes it without SELinux.
    #expect(try labelPlan(process: "", linux: #","mountLabel":"""#).securityLabels == SecurityLabels())
}

@Test func execLabelsOverrideOnlyWhatTheProcessSets() {
    let container = SecurityLabels(appArmorProfile: "container", selinuxLabel: "container_t")
    #expect(container.overridden(by: SecurityLabels()) == container)
    #expect(container.overridden(by: SecurityLabels(appArmorProfile: "exec")) == SecurityLabels(appArmorProfile: "exec", selinuxLabel: "container_t"))
    #expect(SecurityLabels().overridden(by: SecurityLabels(selinuxLabel: "exec_t")) == SecurityLabels(selinuxLabel: "exec_t"))
}

@Test func securityLabelsPersistWithContainerState() throws {
    let plan = try labelPlan(process: #","apparmorProfile":"docker-default""#)
    let id = try ContainerID("label-state")
    let decoded = try ContainerRecord.decode(ContainerRecord(id: id, plan: plan).encoded(), expectedID: id)
    #expect(decoded.securityLabels == SecurityLabels(appArmorProfile: "docker-default"))
}

@Test func unavailableSecurityModulesFailBeforeLaunch() throws {
    // macOS has neither module; on Linux this holds only where each is off.
    if !Kernel.SecurityModule.isAppArmorEnabled {
        #expect(throws: RuntimeError.self) { try SecurityLabelSetup(SecurityLabels(appArmorProfile: "docker-default")) }
    }
    if !Kernel.SecurityModule.isSELinuxEnabled {
        #expect(throws: RuntimeError.self) { try SecurityLabelSetup(SecurityLabels(selinuxLabel: "container_t")) }
    }
    #expect(try SecurityLabelSetup(SecurityLabels()).appArmorExec == nil)
}
