import Foundation
import Testing
@testable import ContainerRuntime

private func profile(_ json: String) throws -> SeccompProfile {
    try JSONDecoder().decode(SeccompProfile.self, from: Data(json.utf8))
}

@Test func seccompActionDataIsValidated() throws {
    #expect(try SeccompProfile.Action.errno.value(nil) == 0x50001)
    #expect(try SeccompProfile.Action.trace.value(65535) == 0x7ff0ffff)
    #expect(try SeccompProfile.Action.kill.value(nil) == SeccompProfile.Action.killThread.value(nil))
    #expect(throws: RuntimeError.self) { try SeccompProfile.Action.errno.value(4096) }
    #expect(throws: RuntimeError.self) { try SeccompProfile.Action.trace.value(65536) }
    #expect(throws: RuntimeError.self) { try SeccompProfile.Action.allow.value(1) }
}

@Test(arguments: [
    #"{"defaultAction":"SCMP_ACT_NOTIFY"}"#,
    #"{"defaultAction":"SCMP_ACT_ALLOW","listenerPath":"/agent.sock"}"#,
    #"{"defaultAction":"SCMP_ACT_ALLOW","architectures":["SCMP_ARCH_UNKNOWN"]}"#,
    #"{"defaultAction":"SCMP_ACT_ALLOW","flags":["SECCOMP_FILTER_FLAG_NEW_LISTENER"]}"#,
    #"{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":[],"action":"SCMP_ACT_ERRNO"}]}"#,
    #"{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["getcwd\u0000"],"action":"SCMP_ACT_ERRNO"}]}"#,
    #"{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["getcwd"],"action":"SCMP_ACT_ERRNO","args":[{"index":6,"value":0,"op":"SCMP_CMP_EQ"}]}]}"#,
    #"{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["getcwd"],"action":"SCMP_ACT_ERRNO","args":[{"index":0,"value":-1,"op":"SCMP_CMP_EQ"}]}]}"#,
    #"{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["getcwd"],"action":"SCMP_ACT_ERRNO","args":[{"index":0,"value":0,"op":"SCMP_CMP_UNKNOWN"}]}]}"#,
])
func seccompRejectsUnsupportedOrMalformedPolicy(_ json: String) {
    #expect(throws: (any Error).self) { try profile(json) }
}

@Test func seccompPreserves64BitArgumentsAndFlagsPresence() throws {
    let value = try profile(#"{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["getcwd"],"action":"SCMP_ACT_ERRNO","args":[{"index":0,"value":18446744073709551615,"valueTwo":9223372036854775808,"op":"SCMP_CMP_MASKED_EQ"}]}]}"#)
    #expect(value.syscalls?[0].args?[0].value == UInt64.max)
    #expect(value.syscalls?[0].args?[0].valueTwo == 1 << 63)
    #expect(try SeccompProfile.kernelFlags(value.flags) == 4)
    #expect(try SeccompProfile.kernelFlags([]) == 0)
    #expect(try SeccompProfile.kernelFlags(["SECCOMP_FILTER_FLAG_TSYNC", "SECCOMP_FILTER_FLAG_LOG"]) == 3)
    #expect(try JSONDecoder().decode(SeccompProfile.self, from: JSONEncoder().encode(value)) == value)
}

@Test func seccompCompilationDoesNotChangeSupervisor() throws {
    guard Kernel.isLinux else { return }
    let before = try String(contentsOfFile: "/proc/self/status", encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("Seccomp") }
    let value = try profile(#"{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["getcwd"],"action":"SCMP_ACT_ERRNO","errnoRet":13}]}"#)
    let code = try Kernel.Seccomp.compile(value)
    #expect(!code.bytes.isEmpty)
    let after = try String(contentsOfFile: "/proc/self/status", encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("Seccomp") }
    #expect(before == after)
    let invalid = try profile(#"{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["sct_nonexistent_syscall"],"action":"SCMP_ACT_ERRNO"}]}"#)
    #expect(throws: RuntimeError.self) { try Kernel.Seccomp.compile(invalid) }
}
