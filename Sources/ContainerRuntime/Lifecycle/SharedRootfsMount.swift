import SystemPackage

/// Cleanup authority for a root bind in the caller's mount namespace. Unlike
/// a private namespace, this mount survives init's exit. Record the original
/// mount ID, root identity, namespace identity and boot before launch; delete
/// detaches only a new mount on that same directory, in that same namespace.
/// As with rootfs setup, the caller must retain exclusive ownership of the tree.
struct SharedRootfsMount: Codable, Sendable, Equatable {
    let originalMountID: UInt64
    let root: FileIdentity
    let namespace: FileIdentity
    let bootID: String

    init(rootfs: String) throws {
        let directory = try Kernel.File.openPath(rootfs, options: [.directory, .noFollow])
        root = try directory.borrowDescriptor { descriptor throws(Errno) in try Kernel.File.status(of: descriptor).identity }
        originalMountID = try Self.mountID(directory)
        namespace = try Kernel.File.status(atPath: "/proc/self/ns/mnt").identity
        bootID = try ProcFS.bootID()
        // A bind below a shared mount would propagate into peer namespaces.
        // Refuse before creating any mount rather than changing the host's
        // parent propagation or pretending the namespace is isolated.
        let table = String(decoding: try ProcFS.read("/proc/self/mountinfo", limit: 4 << 20) ?? [], as: UTF8.self)
        guard let entry = table.split(separator: "\n").first(where: { $0.split(separator: " ").first == Substring(String(originalMountID)) }) else {
            throw RuntimeError("cannot identify the rootfs parent mount")
        }
        let fields = entry.split(separator: " ")
        let optional = fields.dropFirst(6).prefix { $0 != "-" }
        guard !optional.contains(where: { $0.hasPrefix("shared:") }) else {
            throw RuntimeError("an inherited mount namespace requires a private rootfs parent mount")
        }
    }

    /// Read a pinned descriptor's mount ID, which distinguishes a bind from
    /// the covered directory even though their stat device/inode are equal.
    private static func mountID(_ directory: borrowing OwnedFileDescriptor) throws -> UInt64 {
        try directory.withDescriptor { descriptor in
            let text = String(decoding: try ProcFS.read("/proc/self/fdinfo/\(descriptor.rawValue)") ?? [], as: UTF8.self)
            guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("mnt_id:") }),
                  let value = UInt64(line.split(whereSeparator: \.isWhitespace).last ?? "") else {
                throw RuntimeError("cannot read rootfs mount ID")
            }
            return value
        }
    }

    /// Runs after init and its cgroup descendants exit, while the state lock
    /// is held. An unchanged mount ID means setup never installed the bind.
    func remove(rootfs: String) throws {
        guard try ProcFS.bootID() == bootID else { return }
        guard try Kernel.File.status(atPath: "/proc/self/ns/mnt").identity == namespace else {
            throw RuntimeError("delete must run in the mount namespace that owns the inherited rootfs mount")
        }
        let directory: OwnedFileDescriptor
        do { directory = try Kernel.File.openPath(rootfs, options: [.directory, .noFollow]) }
        catch .noSuchFileOrDirectory { return }
        guard try directory.borrowDescriptor({ descriptor throws(Errno) in try Kernel.File.status(of: descriptor).identity }) == root else {
            throw RuntimeError("rootfs was replaced; leaving its mount untouched")
        }
        guard try Self.mountID(directory) != originalMountID else { return }
        try directory.borrowDescriptor { directory throws(Errno) in
            // Use the pinned mount through procfs, avoiding another path walk.
            do {
                try "/proc/self/fd/\(directory.rawValue)".withCString { path in try unsafe Kernel.Mount.unmountDetached(path) }
            } catch { throw (error as? Errno) ?? .ioError }
        }
    }
}
