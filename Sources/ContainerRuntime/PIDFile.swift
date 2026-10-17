#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import SystemPackage

/// Publish a decimal host PID without exposing a partially written file.
/// The sibling temporary name and replacement semantics follow runc.
enum PIDFile {
    static func write(_ pid: Int32, to path: String) throws {
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
        defer { if !published { _ = unsafe temporary.withCString { unsafe unlink($0) } } }
        try file.withDescriptor { descriptor in
            _ = try descriptor.writeAll(Array(String(pid).utf8))
            guard fsync(descriptor.rawValue) == 0 else { throw Errno(rawValue: errno) }
        }
        try file.close()
        let result = unsafe temporary.withCString { source in
            unsafe destination.withCString { target in unsafe rename(source, target) }
        }
        guard result == 0 else { throw Errno(rawValue: errno) }
        published = true
    }
}
