import SystemPackage

/// Byte I/O with safe buffer types: writes take a `RawSpan`, and reads fill a
/// `MutableSpan` or return an array. The unsafe buffers swift-system needs
/// stay here. Code that runs after the workload's resource limits are set
/// (the launch handshake) uses spans over stack storage, never arrays, so a
/// tight RLIMIT_AS cannot fail an allocation there.
extension Kernel.File {
    /// One write(2), retried on EINTR; returns the bytes written.
    static func write(_ descriptor: FileDescriptor, _ bytes: RawSpan) throws(Errno) -> Int {
        do {
            return try bytes.withUnsafeBytes { buffer in try unsafe descriptor.write(buffer) }
        } catch {
            throw (error as? Errno) ?? .ioError
        }
    }

    /// One read(2) into `buffer` starting at `offset`, retried on EINTR;
    /// returns the bytes read, 0 at end of file. Allocates nothing.
    static func read(_ descriptor: FileDescriptor, into buffer: inout MutableSpan<UInt8>, from offset: Int = 0) throws(Errno) -> Int {
        precondition(offset >= 0 && offset <= buffer.count)
        do {
            return try buffer.withUnsafeMutableBufferPointer { bytes in
                try unsafe descriptor.read(into: UnsafeMutableRawBufferPointer(UnsafeMutableBufferPointer(rebasing: bytes[offset...])))
            }
        } catch {
            throw (error as? Errno) ?? .ioError
        }
    }

    /// One read(2) of at most `maxCount` bytes, retried on EINTR; empty at end of file.
    static func read(_ descriptor: FileDescriptor, upTo maxCount: Int) throws(Errno) -> [UInt8] {
        do {
            return try unsafe Array(unsafeUninitializedCapacity: maxCount) { buffer, count in
                count = try unsafe descriptor.read(into: UnsafeMutableRawBufferPointer(buffer))
            }
        } catch {
            throw (error as? Errno) ?? .ioError
        }
    }

    /// Reads until end of file, failing with EFBIG once more than `limit` bytes arrive.
    static func readAll(_ descriptor: FileDescriptor, limit: Int, chunkSize: Int = 16 * 1024) throws(Errno) -> [UInt8] {
        var bytes: [UInt8] = []
        while true {
            let chunk = try read(descriptor, upTo: chunkSize)
            if chunk.isEmpty { return bytes }
            bytes += chunk
            guard bytes.count <= limit else { throw .fileTooLarge }
        }
    }
}
