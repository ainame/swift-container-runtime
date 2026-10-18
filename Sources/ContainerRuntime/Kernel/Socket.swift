#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
#if os(Linux)
import LinuxAPI
#endif
import SystemPackage

extension Kernel {
    /// Unix-domain sockets. Descriptors are close-on-exec, and sends never
    /// raise SIGPIPE (MSG_NOSIGNAL), so a vanished peer is an error. Creating
    /// and accepting sockets is Linux-only, so that promise always holds.
    enum Socket {
        /// A close-on-exec SOCK_SEQPACKET socket.
        static func unixSequencedPacket() throws(Errno) -> OwnedFileDescriptor {
            #if os(Linux)
            try owned(linux_unix_seqpacket_socket())
            #else
            throw .noFunction
            #endif
        }

        /// A close-on-exec SOCK_STREAM socket.
        static func unixStream() throws(Errno) -> OwnedFileDescriptor {
            #if os(Linux)
            try owned(linux_unix_stream_socket())
            #else
            throw .noFunction
            #endif
        }

        /// socketpair(2) of close-on-exec SOCK_STREAM sockets; the caller takes
        /// ownership of both ends at once.
        static func unixStreamPair() throws(Errno) -> (FileDescriptor, FileDescriptor) {
            #if os(Linux)
            var pair: [Int32] = [-1, -1]
            guard unsafe linux_unix_stream_socketpair(&pair) == 0 else { throw .current }
            return (FileDescriptor(rawValue: pair[0]), FileDescriptor(rawValue: pair[1]))
            #else
            throw .noFunction
            #endif
        }

        /// bind(2) to `sunPath`, the exact `sun_path` bytes: a filesystem
        /// path with its terminating NUL, or NUL and an abstract name.
        static func bind(_ socket: FileDescriptor, sunPath: [UInt8]) throws(Errno) {
            try unsafe withAddress(sunPath) { address, length in unsafe libcBind(socket.rawValue, address, length) }
        }

        /// connect(2) to `sunPath`, as for `bind`.
        static func connect(_ socket: FileDescriptor, sunPath: [UInt8]) throws(Errno) {
            try unsafe withAddress(sunPath) { address, length in unsafe libcConnect(socket.rawValue, address, length) }
        }

        static func listen(_ socket: FileDescriptor, backlog: Int32) throws(Errno) {
            guard libcListen(socket.rawValue, backlog) == 0 else { throw .current }
        }

        /// accept(2) of a close-on-exec connection on an owned listener.
        static func accept(_ listener: borrowing OwnedFileDescriptor) throws(Errno) -> OwnedFileDescriptor {
            #if os(Linux)
            let raw: Int32
            do {
                raw = try listener.withDescriptor { linux_accept_cloexec($0.rawValue) }
            } catch {
                throw (error as? Errno) ?? .badFileDescriptor
            }
            return try owned(raw)
            #else
            throw .noFunction
            #endif
        }

        /// One send(2), retried on EINTR; returns the bytes sent.
        static func send(_ socket: FileDescriptor, _ bytes: RawSpan) throws(Errno) -> Int {
            let result = bytes.withUnsafeBytes { buffer in
                var result: Int
                repeat { result = unsafe libcSend(socket.rawValue, buffer.baseAddress, buffer.count, noSignal) }
                while result < 0 && errno == EINTR
                return result
            }
            guard result >= 0 else { throw .current }
            return result
        }

        /// Sends `payload` and one SCM_RIGHTS descriptor in a single message:
        /// no length prefix or encoding, as runc's `cmsg.SendRawFd`. A short
        /// send (not expected for a few bytes on a stream) is EIO.
        static func sendDescriptor(_ descriptor: FileDescriptor, over socket: FileDescriptor, payload: [UInt8]) throws(Errno) {
            let payloadSize = MemoryLayout<Int32>.size
            let space = controlSpace(payloadSize)
            // CMSG_LEN(0) is the aligned header size, where CMSG_DATA begins.
            let dataOffset = controlLength(0)
            guard dataOffset + payloadSize <= space else { throw .invalidArgument }
            var header = cmsghdr()
            header.cmsg_len = numericCast(controlLength(payloadSize))
            header.cmsg_level = Int32(SOL_SOCKET)
            header.cmsg_type = Int32(SCM_RIGHTS)
            var payload = payload
            let result: Errno? = payload.withUnsafeMutableBytes { bytes in
                // Raw control bytes with cmsghdr's alignment, zeroed so padding is
                // defined. The header value and the descriptor are copied in as plain
                // bytes at disjoint offsets; the memory is never bound to cmsghdr.
                withUnsafeTemporaryAllocation(byteCount: space, alignment: MemoryLayout<cmsghdr>.alignment) { control in
                    unsafe control.initializeMemory(as: UInt8.self, repeating: 0)
                    unsafe control.storeBytes(of: header, toByteOffset: 0, as: cmsghdr.self)
                    unsafe control.storeBytes(of: descriptor.rawValue, toByteOffset: dataOffset, as: Int32.self)
                    var vector = unsafe iovec(iov_base: bytes.baseAddress, iov_len: bytes.count)
                    return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                        var message = unsafe msghdr()
                        unsafe message.msg_iov = vectorPointer
                        unsafe message.msg_iovlen = 1
                        unsafe message.msg_control = control.baseAddress
                        unsafe message.msg_controllen = numericCast(space)
                        var sent: Int
                        repeat { sent = unsafe sendmsg(socket.rawValue, &message, noSignal) }
                        while sent < 0 && errno == EINTR
                        guard sent >= 0 else { return .current }
                        return sent == bytes.count ? nil : .ioError
                    }
                }
            }
            if let result { throw result }
        }

        #if os(Linux)
        private static let noSignal = Int32(MSG_NOSIGNAL)
        private static func controlSpace(_ length: Int) -> Int { linux_cmsg_space(length) }
        private static func controlLength(_ length: Int) -> Int { linux_cmsg_len(length) }
        #else
        private static let noSignal: Int32 = 0
        private static func controlSpace(_ length: Int) -> Int {
            let align = MemoryLayout<UInt32>.size
            return (MemoryLayout<cmsghdr>.size + align - 1) / align * align + (length + align - 1) / align * align
        }
        private static func controlLength(_ length: Int) -> Int {
            let align = MemoryLayout<UInt32>.size
            return (MemoryLayout<cmsghdr>.size + align - 1) / align * align + length
        }
        #endif

        private static func owned(_ raw: Int32) throws(Errno) -> OwnedFileDescriptor {
            guard raw >= 0 else { throw .current }
            return OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
        }

        /// Builds a sockaddr_un for `sunPath`; ENAMETOOLONG when it does not fit.
        private static func withAddress(
            _ sunPath: [UInt8], _ call: (UnsafePointer<sockaddr>, socklen_t) -> Int32
        ) throws(Errno) {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            guard sunPath.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw .fileNameTooLong }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                for (index, byte) in sunPath.enumerated() { unsafe buffer[index] = byte }
            }
            // sun_path directly follows the family (and, on Darwin, sun_len).
            let length = socklen_t(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + sunPath.count)
            let result = withUnsafePointer(to: &address) { pointer in
                unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe call($0, length) }
            }
            guard result == 0 else { throw .current }
        }
    }
}

// The libc socket calls, reached at file scope where Kernel.Socket's
// methods of the same names do not shadow them.
private func libcBind(_ socket: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    unsafe bind(socket, address, length)
}
private func libcConnect(_ socket: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    unsafe connect(socket, address, length)
}
private func libcListen(_ socket: Int32, _ backlog: Int32) -> Int32 { listen(socket, backlog) }
private func libcSend(_ socket: Int32, _ bytes: UnsafeRawPointer?, _ count: Int, _ flags: Int32) -> Int {
    unsafe send(socket, bytes, count, flags)
}
