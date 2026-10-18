import SystemPackage

/// Rootful UID/GID mappings installed by the supervisor while the launcher
/// waits in its new user namespace. No mapping helpers or rootless grants
/// are implied: the caller must be root in the parent namespace.
struct UserNamespace: Sendable {
    let uidMap: String
    let gidMap: String

    init(uid: [OCIConfiguration.IDMapping], gid: [OCIConfiguration.IDMapping]) throws {
        uidMap = try Self.validated(uid, field: "uidMappings")
        gidMap = try Self.validated(gid, field: "gidMappings")
    }

    /// Reject overlaps in either ID space before asking the kernel to install
    /// a map. Linux reserves ID -1 and permits at most 340 mapping extents.
    private static func validated(_ entries: [OCIConfiguration.IDMapping], field: String) throws -> String {
        guard !entries.isEmpty, entries.count <= 340 else {
            throw RuntimeError("config.json: linux.\(field) requires 1...340 mappings")
        }
        var containerRanges: [Range<UInt64>] = [], hostRanges: [Range<UInt64>] = []
        for entry in entries {
            let container = UInt64(entry.containerID), host = UInt64(entry.hostID), size = UInt64(entry.size)
            guard size > 0, container + size <= UInt64(UInt32.max), host + size <= UInt64(UInt32.max) else {
                throw RuntimeError("config.json: linux.\(field) has an empty or overflowing range")
            }
            let inside = container..<(container + size), outside = host..<(host + size)
            guard !containerRanges.contains(where: { $0.overlaps(inside) }), !hostRanges.contains(where: { $0.overlaps(outside) }) else {
                throw RuntimeError("config.json: linux.\(field) contains overlapping ranges")
            }
            containerRanges.append(inside); hostRanges.append(outside)
        }
        guard containerRanges.contains(where: { $0.contains(0) }) else {
            throw RuntimeError("config.json: linux.\(field) must map container ID 0 for init setup")
        }
        return entries.map { "\($0.containerID) \($0.hostID) \($0.size)\n" }.joined()
    }

    /// The launcher is still this supervisor's live child, blocked on the
    /// release socket. Its PID cannot be reused while these procfs writes run.
    func install(for launcher: pid_t) throws {
        guard Kernel.Process.effectiveUserID == 0 else {
            throw RuntimeError("rootful user namespace mappings require root in the parent namespace")
        }
        for (name, value) in [("uid_map", uidMap), ("gid_map", gidMap)] {
            try "/proc/\(launcher)/\(name)".withCString { path in
                try value.withCString { value in try unsafe Kernel.File.writeProcFile(path, value) }
            }
        }
    }
}
