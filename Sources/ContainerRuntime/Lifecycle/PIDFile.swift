import SystemPackage

/// Publish a decimal host PID without exposing a partially written file.
/// The sibling temporary name and replacement semantics follow runc.
enum PIDFile {
    static func write(_ pid: pid_t, to path: String) throws {
        // An empty option means no PID file, as in runc. Reject embedded NUL
        // before passing either name to a C filesystem interface.
        guard !path.isEmpty else { return }
        guard !path.utf8.contains(0) else { throw RuntimeError("PID file path contains NUL") }
        let destination = FilePath(path)
        guard let name = destination.lastComponent else { throw RuntimeError("invalid PID file path \(path)") }
        let temporary = destination.removingLastComponent().appending("." + name.string)

        // Never follow an existing temporary symlink or truncate another
        // writer's file. Rename replaces a destination symlink itself.
        var file = OwnedFileDescriptor(takingOwnershipOf: try FileDescriptor.open(
            temporary, .writeOnly, options: [.create, .exclusiveCreate, .closeOnExec],
            permissions: FilePermissions(rawValue: 0o666)))
        var published = false
        defer { if !published { try? Kernel.File.remove(temporary.string) } }
        try file.withDescriptor { descriptor in
            _ = try descriptor.writeAll(Array(String(pid).utf8))
            try Kernel.File.synchronize(descriptor)
        }
        try file.close()
        try Kernel.File.rename(temporary.string, to: destination.string)
        published = true
    }
}
