import SystemPackage

/// A single owner around SystemPackage's copyable descriptor value.
/// Descriptors passed to a scoped callback must not be closed or escape it.
struct OwnedFileDescriptor: ~Copyable {
    private var descriptor: FileDescriptor?

    init(takingOwnershipOf descriptor: FileDescriptor) {
        precondition(descriptor.rawValue >= 0)
        self.descriptor = descriptor
    }

    /// An owner that holds nothing yet; borrowing it throws `EBADF`.
    init() {
        descriptor = nil
    }

    borrowing func withDescriptor<Result>(
        _ body: (FileDescriptor) throws -> Result
    ) throws -> Result {
        guard let descriptor else { throw Errno.badFileDescriptor }
        // A copyable descriptor does not extend this owner's resource lifetime.
        return try withExtendedLifetime(self) { try body(descriptor) }
    }

    mutating func close() throws {
        guard let descriptor else { return }
        // Invalidate ownership before close, including when close reports an
        // error. Retrying close can close a descriptor reused by another open.
        self.descriptor = nil
        try descriptor.close()
    }

    consuming func relinquish() throws(Errno) -> FileDescriptor {
        guard let descriptor else { throw .badFileDescriptor }
        self.descriptor = nil
        return descriptor
    }

    deinit {
        try? descriptor?.close()
    }
}

extension OwnedFileDescriptor {
    /// Reads to EOF, failing once more than `limit` bytes arrive.
    func readAll(limit: Int) throws -> [UInt8] {
        try withDescriptor { descriptor in
            var bytes: [UInt8] = []
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = try chunk.withUnsafeMutableBytes { buffer in
                    unsafe try descriptor.read(into: buffer)
                }
                if count == 0 { return bytes }
                bytes += chunk[..<count]
                guard bytes.count <= limit else { throw RuntimeError("input exceeds \(limit) bytes") }
            }
        }
    }
}
