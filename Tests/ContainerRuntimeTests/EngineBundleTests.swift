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

@Test func capturedEngineCreatePlansEnforcedDevicePolicy() throws {
    let config = try JSONDecoder().decode(OCIConfiguration.self, from: engineFixture("create.config.json"))
    let plan = try OCIRunPlan(config, bundle: FilePath("/bundle"), rootfs: FilePath("/rootfs"))
    let policy = try #require(plan.cgroup.resources.devicePolicy)
    #expect(!policy.defaultAllow)
    #expect(!DeviceFilter.bytecode(policy).isEmpty)
}

@Test func capturedEngineExecProcessIsSupported() throws {
    let data = try engineFixture("exec.process.json")
    let process = try JSONDecoder().decode(OCIConfiguration.Process.self, from: data)
    let plan = try OCIProcessPlan(process)
    #expect(plan.arguments == ["/bin/busybox", "sleep", "300"])
    #expect(plan.security.noNewPrivileges)
}

@Test func capturedEngineMountsPlanWithDevicePolicy() throws {
    let config = try JSONDecoder().decode(OCIConfiguration.self, from: engineFixture("create.config.json"))
    let plan = try OCIRunPlan(config, bundle: FilePath("/bundle"), rootfs: FilePath("/rootfs"))
    #expect(plan.mounts.contains { $0.type == .sysfs && $0.flags.contains(.readonly) })
    #expect(plan.mounts.contains { $0.type == .mqueue && $0.destinationPath == "/dev/mqueue" })
    #expect(plan.mounts.contains { $0.type == .tmpfs && $0.destinationPath == "/dev/shm" })
}

@Test func capturedImageBindBundlePlansItsOriginalRestrictions() throws {
    let config = try JSONDecoder().decode(OCIConfiguration.self, from: engineFixture("image-bind/create.config.json"))
    let plan = try OCIRunPlan(config, bundle: FilePath("/bundle"), rootfs: FilePath("/rootfs"))
    let binds = plan.mounts.filter { $0.type == .bind }
    #expect(binds.count == 2)
    #expect(binds.allSatisfy { $0.recursiveBind && $0.propagation == .recursivePrivate })
    #expect(binds.first { $0.destinationPath == "/etc/resolv.conf" }?.flags.contains(.readonly) == true)
    #expect(binds.first { $0.destinationPath == "/volume" }?.clearedFlags.contains(.readonly) == true)
    #expect(plan.cgroup.resources.devicePolicy != nil)
}

@Test func capturedImageNetworkBundlePlansSuppliedNamespace() throws {
    let config = try JSONDecoder().decode(OCIConfiguration.self, from: engineFixture("image-network/create.config.json"))
    let plan = try OCIRunPlan(config, bundle: FilePath("/bundle"), rootfs: FilePath("/rootfs"))
    let path = try #require(plan.networkNamespacePath)
    #expect(FilePath(path).isAbsolute)
    #expect(!plan.namespaces.contains(.network))
    #expect(plan.namespaces.contains(.mount))
    #expect(plan.mounts.filter { $0.type == .bind }.count == 2)
    #expect(plan.cgroup.resources.devicePolicy != nil)
}

@Test(arguments: ["default", "deny-getcwd"])
func capturedEngineSeccompPoliciesCompileAndPersist(_ name: String) throws {
    let config = try JSONDecoder().decode(OCIConfiguration.self, from: engineFixture("seccomp-reference/\(name).config.json"))
    let plan = try OCIRunPlan(config, bundle: FilePath("/bundle"), rootfs: FilePath("/rootfs"))
    let policy = try #require(plan.seccomp)
    #expect(!(policy.syscalls ?? []).isEmpty)
    let id = try ContainerID("seccomp-fixture")
    let state = ContainerRecord(id: id, plan: plan)
    let restored = try ContainerRecord.decode(state.encoded(), expectedID: id)
    #expect(restored.seccomp == policy)
    if Kernel.isLinux { #expect(!(try Kernel.Seccomp.compile(policy)).bytes.isEmpty) }
}
