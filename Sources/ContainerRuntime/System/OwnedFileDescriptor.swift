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

    /// `withDescriptor` for bodies that throw `Errno` or return an owned
    /// value; `EBADF` when this owner holds nothing.
    borrowing func borrowDescriptor<Result: ~Copyable>(
        _ body: (FileDescriptor) throws(Errno) -> Result
    ) throws(Errno) -> Result {
        guard let descriptor else { throw .badFileDescriptor }
        return try withExtendedLifetime(self) { () throws(Errno) -> Result in try body(descriptor) }
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
    /// For steps that return a failure instead of throwing: the body's error,
    /// or `EBADF` when this owner holds nothing. (`try? withDescriptor` would
    /// flatten the body's nil, meaning success, into its fallback.)
    borrowing func failure(in body: (FileDescriptor) -> Errno?) -> Errno? {
        failure(in: body, whenClosed: .badFileDescriptor)
    }

    /// `failure(in:)` for any failure type: the body's failure, or `closed`
    /// when this owner holds nothing.
    borrowing func failure<Failure>(in body: (FileDescriptor) -> Failure?, whenClosed closed: Failure) -> Failure? {
        do { return try withDescriptor(body) } catch { return closed }
    }

    /// Reads to EOF, failing once more than `limit` bytes arrive.
    func readAll(limit: Int) throws -> [UInt8] {
        try withDescriptor { descriptor in
            do {
                return try Kernel.File.readAll(descriptor, limit: limit)
            } catch .fileTooLarge {
                throw RuntimeError("input exceeds \(limit) bytes")
            }
        }
    }
}
