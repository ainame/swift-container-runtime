import SystemPackage

/// Resolves bundle directories and reads the bounded OCI configuration.
enum BundleConfiguration {
    /// Resolves symlinks and confirms the result is a directory. Paths that do
    /// not round-trip through String are rejected, because launch strings are
    /// built from `FilePath.string` and would otherwise be silently repaired.
    static func resolveDirectory(_ path: FilePath, role: String) throws -> FilePath {
        let resolved: FilePath
        do {
            resolved = try Kernel.File.resolvedPath(path)
        } catch {
            throw RuntimeError("resolve \(role) \(path): \(error)")
        }
        guard FilePath(resolved.string) == resolved else {
            throw RuntimeError("\(role) \(resolved) is not valid UTF-8, which this runtime does not support")
        }
        do {
            let descriptor = try FileDescriptor.open(resolved, .readOnly, options: [.directory, .closeOnExec])
            var owner = OwnedFileDescriptor(takingOwnershipOf: descriptor)
            try owner.close()
        } catch {
            throw RuntimeError("\(role) \(resolved) is not an accessible directory: \(error)")
        }
        return resolved
    }

    static func read(_ path: FilePath) throws -> [UInt8] {
        let limit = 1 << 20
        let owner: OwnedFileDescriptor
        do {
            owner = OwnedFileDescriptor(takingOwnershipOf: try FileDescriptor.open(path, .readOnly, options: .closeOnExec))
        } catch {
            throw RuntimeError("open \(path): \(error)")
        }
        do {
            return try owner.withDescriptor { descriptor in
                do {
                    return try Kernel.File.readAll(descriptor, limit: limit, chunkSize: 64 * 1024)
                } catch .fileTooLarge {
                    throw RuntimeError("\(path) exceeds 1 MiB")
                }
            }
        } catch let error as RuntimeError {
            throw error
        } catch {
            throw RuntimeError("read \(path): \(error)")
        }
    }
}
