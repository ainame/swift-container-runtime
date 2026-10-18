/// One validated `linux.sysctl` entry, written by the init through the
/// container's `/proc/sys` after `pivot_root`, as runc's writeSystemProperty.
public struct Sysctl: Sendable, Equatable {
    /// The dotted name, such as `net.ipv4.ip_unprivileged_port_start`.
    public let key: String
    public let value: String

    /// The procfs file: dots become slashes below `/proc/sys`.
    var path: String { "/proc/sys/" + key.split(separator: ".").joined(separator: "/") }

    /// Whether the entry configures the network namespace, which must not be the host's.
    var isNetwork: Bool { key.hasPrefix("net.") }

    /// runc's validator: only sysctls of a namespace this container owns are
    /// allowed, so no entry can change the host. IPC sysctls need an ipc
    /// namespace, `net.*` a network namespace (created or joined; a joined
    /// host namespace is refused before launch), and `kernel.domainname` a
    /// uts namespace. Entries are applied in key order.
    /// - Throws: `RuntimeError` naming the refused key.
    static func validated(_ entries: [String: String], creating namespaces: Set<OCIRunPlan.Namespace>, joinsNetwork: Bool) throws -> [Sysctl] {
        try entries.keys.sorted().map { key in
            let value = entries[key]!
            let field = "config.json: linux.sysctl \(key)"
            // Each dotted component names one /proc/sys path component.
            let components = key.split(separator: ".", omittingEmptySubsequences: false)
            guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != ".." && !$0.contains("/") }),
                  !key.utf8.contains(0), !value.utf8.contains(0) else {
                throw RuntimeError("\(field) is not a valid sysctl name or value")
            }
            if ipcKeys.contains(key) || key.hasPrefix("fs.mqueue.") {
                guard namespaces.contains(.ipc) else { throw RuntimeError("\(field) is not allowed in the host's ipc namespace") }
            } else if key.hasPrefix("net.") {
                guard namespaces.contains(.network) || joinsNetwork else {
                    throw RuntimeError("\(field) is not allowed in the host's network namespace")
                }
            } else if key == "kernel.hostname" {
                throw RuntimeError("\(field) is not allowed; use the hostname field")
            } else if key == "kernel.domainname" {
                guard namespaces.contains(.uts) else { throw RuntimeError("\(field) is not allowed in the host's uts namespace") }
            } else {
                throw RuntimeError("\(field) is not in a separate kernel namespace")
            }
            return Sysctl(key: key, value: value)
        }
    }

    private static let ipcKeys: Set<String> = [
        "kernel.msgmax", "kernel.msgmnb", "kernel.msgmni", "kernel.sem",
        "kernel.shmall", "kernel.shmmax", "kernel.shmmni", "kernel.shm_rmid_forced",
    ]
}
