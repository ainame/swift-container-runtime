import SystemPackage

/// UID/GID mappings installed by the supervisor while the launcher waits in
/// its new user namespace, following runc's nsexec. Root in the parent
/// namespace writes both maps directly. An unprivileged (rootless) caller
/// writes a map directly only when it maps just its own ID, which the kernel
/// allows the namespace owner; any other map goes through the setuid
/// `newuidmap`/`newgidmap` helpers, which check /etc/subuid and /etc/subgid.
struct UserNamespace: Sendable {
    /// One `containerID hostID size` line per extent, as uid_map takes it.
    let uidMap: String
    let gidMap: String
    /// The same extents as `newuidmap`/`newgidmap` arguments after the PID.
    let uidHelperArguments: [String]
    let gidHelperArguments: [String]
    /// The single (container, host) pair of a one-ID map, or nil.
    private let singleUID: UInt32?
    private let singleGID: UInt32?

    init(uid: [OCIConfiguration.IDMapping], gid: [OCIConfiguration.IDMapping]) throws {
        uidMap = try Self.validated(uid, field: "uidMappings")
        gidMap = try Self.validated(gid, field: "gidMappings")
        uidHelperArguments = uid.flatMap { [String($0.containerID), String($0.hostID), String($0.size)] }
        gidHelperArguments = gid.flatMap { [String($0.containerID), String($0.hostID), String($0.size)] }
        // Validation requires container ID 0 to be mapped, so a one-ID map is 0 → hostID.
        singleUID = uid.count == 1 && uid[0].size == 1 ? uid[0].hostID : nil
        singleGID = gid.count == 1 && gid[0].size == 1 ? gid[0].hostID : nil
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

    /// True when an unprivileged caller writes the GID map itself and must
    /// first deny setgroups in the namespace, as runc does when the GID map
    /// is exactly `0 → egid` of size 1 (runc's requiresRootOrMappingTool).
    /// The workload then keeps its inherited supplementary groups.
    func deniesSetgroups(effectiveUID: uid_t, effectiveGID: gid_t) -> Bool {
        effectiveUID != 0 && singleGID == effectiveGID
    }

    /// Runs in the supervisor. The launcher is still this supervisor's live
    /// child, blocked on the release socket, so its PID cannot be reused
    /// while these procfs writes or helpers run.
    ///
    /// - Throws: `RuntimeError` when a map cannot be written, or when a
    ///   rootless map needs a helper that is missing or refuses it.
    func install(for launcher: pid_t) throws {
        let uid = Kernel.Process.effectiveUserID, gid = Kernel.Process.effectiveGroupID
        if uid == 0 {
            try Self.write(uidMap, to: "uid_map", of: launcher)
            try Self.write(gidMap, to: "gid_map", of: launcher)
            return
        }
        // Rootless, in runc's order: setgroups (only for a direct GID map),
        // then the UID map, then the GID map.
        if deniesSetgroups(effectiveUID: uid, effectiveGID: gid) {
            try Self.write("deny", to: "setgroups", of: launcher)
        }
        if singleUID == uid {
            try Self.write(uidMap, to: "uid_map", of: launcher)
        } else {
            try Self.runHelper("newuidmap", launcher: launcher, arguments: uidHelperArguments, field: "uidMappings")
        }
        if singleGID == gid {
            try Self.write(gidMap, to: "gid_map", of: launcher)
        } else {
            try Self.runHelper("newgidmap", launcher: launcher, arguments: gidHelperArguments, field: "gidMappings")
        }
    }

    private static func write(_ value: String, to name: String, of launcher: pid_t) throws {
        do {
            try "/proc/\(launcher)/\(name)".withCString { path in
                try value.withCString { value in try unsafe Kernel.File.writeProcFile(path, value) }
            }
        } catch {
            throw RuntimeError("write user namespace \(name): \(error)")
        }
    }

    /// Runs `newuidmap`/`newgidmap PID inside outside count...` from PATH, as
    /// runc does for a rootless map other than the caller's own ID. Its
    /// output is collected for the error.
    private static func runHelper(_ helper: String, launcher: pid_t, arguments: [String], field: String) throws {
        let pipe = try FileDescriptor.pipe(options: .closeOnExec)
        let reader = OwnedFileDescriptor(takingOwnershipOf: pipe.readEnd)
        var writer = OwnedFileDescriptor(takingOwnershipOf: pipe.writeEnd)
        let pid: pid_t
        do {
            pid = try Kernel.Process.spawn([helper, String(launcher)] + arguments, output: pipe.writeEnd, closing: pipe.readEnd)
        } catch {
            throw RuntimeError(
                "rootless linux.\(field) other than the caller's own ID need \(helper) (from the uidmap package): \(error)")
        }
        // Until waitpid reaps it, this PID is still our child; never leave it running.
        var reaped = false
        defer {
            if !reaped {
                try? Kernel.Process.signal(pid, Kernel.Signal.kill)
                _ = try? Kernel.Process.wait(pid)
            }
        }
        try writer.close()
        let output = String(decoding: try reader.readAll(limit: 64 * 1024), as: UTF8.self)
        let status: Int32
        do { status = try Kernel.Process.wait(pid) } catch { throw RuntimeError("wait for \(helper): \(error)") }
        reaped = true
        guard status == 0 else {
            let message = output.split(separator: "\n").last.map(String.init) ?? "wait status \(status)"
            throw RuntimeError("\(helper) refused linux.\(field) (check /etc/sub\(helper == "newuidmap" ? "uid" : "gid")): \(message)")
        }
    }
}
