import Testing
@testable import ContainerRuntime

private let isolated: Set<OCIRunPlan.Namespace> = [.mount, .network, .ipc, .uts]

@Test func sysctlsAreSortedAndMappedToProcfs() throws {
    let entries = try Sysctl.validated(
        ["net.ipv4.ping_group_range": "0 2147483647", "kernel.shmmax": "1024", "net.ipv4.ip_unprivileged_port_start": "0"],
        creating: isolated, joinsNetwork: false)
    #expect(entries.map(\.key) == ["kernel.shmmax", "net.ipv4.ip_unprivileged_port_start", "net.ipv4.ping_group_range"])
    #expect(entries[1].path == "/proc/sys/net/ipv4/ip_unprivileged_port_start")
    #expect(entries[2].value == "0 2147483647")
    #expect(entries[1].isNetwork && !entries[0].isNetwork)
}

@Test func networkSysctlsMayUseAJoinedNamespace() throws {
    #expect(try Sysctl.validated(["net.core.somaxconn": "1024"], creating: [.mount], joinsNetwork: true).count == 1)
}

/// A refused entry, the namespaces the container creates, and the reason.
struct RefusedSysctl: Sendable, CustomTestStringConvertible {
    let key: String
    let namespaces: Set<OCIRunPlan.Namespace>
    let reason: String
    var testDescription: String { key }
}

@Test(arguments: [
    RefusedSysctl(key: "net.ipv4.ip_forward", namespaces: [.mount, .ipc, .uts], reason: "network namespace"),
    RefusedSysctl(key: "kernel.shmmax", namespaces: [.mount, .network, .uts], reason: "ipc namespace"),
    RefusedSysctl(key: "fs.mqueue.msg_max", namespaces: [.mount, .network, .uts], reason: "ipc namespace"),
    RefusedSysctl(key: "kernel.domainname", namespaces: [.mount, .network, .ipc], reason: "uts namespace"),
    RefusedSysctl(key: "kernel.hostname", namespaces: isolated, reason: "hostname field"),
    RefusedSysctl(key: "vm.swappiness", namespaces: isolated, reason: "separate kernel namespace"),
    RefusedSysctl(key: "net..ipv4", namespaces: isolated, reason: "not a valid"),
    RefusedSysctl(key: "net.ipv4/../x", namespaces: isolated, reason: "not a valid"),
    RefusedSysctl(key: "net.ipv4...", namespaces: isolated, reason: "not a valid"),
])
func sysctlsOutsideAnOwnedNamespaceAreRefused(_ refused: RefusedSysctl) {
    #expect {
        try Sysctl.validated([refused.key: "1"], creating: refused.namespaces, joinsNetwork: false)
    } throws: { error in
        "\(error)".contains(refused.reason) && "\(error)".contains("linux.sysctl")
    }
}
