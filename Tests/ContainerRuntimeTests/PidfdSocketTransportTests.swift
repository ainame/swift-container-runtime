#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import LinuxAPI
import SystemPackage
import Testing
@testable import ContainerRuntime

// The transport in-process over a real socketpair, without forking: the
// pidfd names the test process, which is what the forked init would send
// for itself. Launch-level failures and their cleanup are covered by
// scripts/pidfd-socket-integration.sh.

/// A connected stream pair: sender, receiver.
private func streamPair() throws -> (Int32, Int32) {
    var pair: [Int32] = [-1, -1]
    try #require(unsafe linux_unix_stream_socketpair(&pair) == 0)
    return (pair[0], pair[1])
}

private func owned(_ raw: Int32) -> OwnedFileDescriptor {
    OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
}

/// Receives one message: its payload, and each SCM_RIGHTS descriptor.
private func receive(_ socket: FileDescriptor) -> (payload: [UInt8], descriptors: [Int32], flags: Int32)? {
    var payload = [UInt8](repeating: 0, count: 64)
    let space = 256
    return payload.withUnsafeMutableBytes { bytes in
        withUnsafeTemporaryAllocation(byteCount: space, alignment: MemoryLayout<cmsghdr>.alignment) { control in
            unsafe control.initializeMemory(as: UInt8.self, repeating: 0)
            var vector = unsafe iovec(iov_base: bytes.baseAddress, iov_len: bytes.count)
            return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                var message = unsafe msghdr()
                unsafe message.msg_iov = vectorPointer
                unsafe message.msg_iovlen = 1
                unsafe message.msg_control = control.baseAddress
                unsafe message.msg_controllen = numericCast(space)
                let count = unsafe recvmsg(socket.rawValue, &message, Int32(MSG_CMSG_CLOEXEC))
                guard count >= 0 else { return nil }
                // Walk the headers by copying each out as plain bytes.
                let headerSize = linux_cmsg_len(0)
                var descriptors: [Int32] = []
                var offset = 0
                let used = Int(unsafe message.msg_controllen)
                while offset + headerSize <= used {
                    let header = unsafe control.loadUnaligned(fromByteOffset: offset, as: cmsghdr.self)
                    let length = Int(header.cmsg_len)
                    guard length >= headerSize, offset + length <= used else { break }
                    if header.cmsg_level == Int32(SOL_SOCKET) && header.cmsg_type == Int32(SCM_RIGHTS) {
                        var at = offset + headerSize
                        while at + 4 <= offset + length {
                            descriptors.append(unsafe control.loadUnaligned(fromByteOffset: at, as: Int32.self))
                            at += 4
                        }
                    }
                    offset += linux_cmsg_space(length - headerSize)
                }
                let flags = unsafe message.msg_flags
                return (unsafe Array(bytes.prefix(count)), descriptors, flags)
            }
        }
    }
}

private func fdinfoPid(_ descriptor: Int32) throws -> String? {
    let file = try FileDescriptor.open(FilePath("/proc/self/fdinfo/\(descriptor)"), .readOnly, options: .closeOnExec)
    defer { try? file.close() }
    var text: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 512)
    while true {
        let count = try chunk.withUnsafeMutableBytes { bytes in unsafe try file.read(into: bytes) }
        if count == 0 { break }
        text += chunk.prefix(count)
    }
    let line = String(decoding: text, as: UTF8.self).split(separator: "\n").first { $0.hasPrefix("Pid:") }
    return line.map { String($0.dropFirst(4).filter { $0 != " " && $0 != "\t" }) }
}

@Test(arguments: [PidfdLabel.standard, .setns])
func handOffSendsTheLabelWithOnePidfd(_ label: PidfdLabel) throws {
    let (sender, receiverRaw) = try streamPair()
    let receiver = owned(receiverRaw)
    let socket = PidfdSocket(connected: owned(sender), address: try PidfdSocketAddress("/unused"))
    #expect(socket.handOff(label: label) == nil)
    // The connection is closed after the hand-off, whatever the outcome.
    #expect(socket.isClosed)
    let message = try #require(try receiver.withDescriptor { receive($0) })
    // Close every received descriptor, including unexpected extras.
    defer { for descriptor in message.descriptors { _ = close(descriptor) } }
    #expect(message.payload == Array(label.rawValue.utf8))
    #expect(message.flags & Int32(MSG_CTRUNC) == 0)
    try #require(message.descriptors.count == 1)
    #expect(try fdinfoPid(message.descriptors[0]) == String(getpid()))
    // The sender closed its connection: the peer sees EOF, with no more data.
    let eof = try #require(try receiver.withDescriptor { receive($0) })
    #expect(eof.payload.isEmpty && eof.descriptors.isEmpty)
}

@Test func handOffReportsAClosedListenerAndClosesItsConnection() throws {
    let (sender, receiver) = try streamPair()
    _ = close(receiver)
    let socket = PidfdSocket(connected: owned(sender), address: try PidfdSocketAddress("/unused"))
    // MSG_NOSIGNAL: EPIPE is returned rather than SIGPIPE killing the test.
    let failure = socket.handOff(label: .standard)
    #expect(failure?.stage == .pidfdSend)
    #expect(failure?.error == .brokenPipe)
    #expect(socket.isClosed)
}
#endif
