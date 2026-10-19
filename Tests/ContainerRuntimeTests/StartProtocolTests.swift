import SystemPackage
import Testing
@testable import ContainerRuntime

@Test func startPacketSendPreservesTheSocketError() throws {
    let pipe = try FileDescriptor.pipe(options: .closeOnExec)
    let reader = OwnedFileDescriptor(takingOwnershipOf: pipe.readEnd)
    let writer = OwnedFileDescriptor(takingOwnershipOf: pipe.writeEnd)
    // A real kernel ENOTSOCK must survive the helper rather than becoming a
    // Bool whose caller later consults unrelated thread-local errno.
    #expect(throws: Errno.notSocket) { try StartProtocol.sendPacket(writer, StartProtocol.request) }
    _ = reader
}

@Test func startPacketReadFailureIsDistinctFromEOF() throws {
    let pipe = try FileDescriptor.pipe(options: .closeOnExec)
    let reader = OwnedFileDescriptor(takingOwnershipOf: pipe.readEnd)
    var writer = OwnedFileDescriptor(takingOwnershipOf: pipe.writeEnd)
    try writer.close()
    #expect(try StartProtocol.receivePacket(reader) == nil)
    let closed = OwnedFileDescriptor()
    #expect(throws: Errno.badFileDescriptor) { try StartProtocol.receivePacket(closed) }
}

@Test func startPacketReadinessSeparatesTimeoutHangupAndFailure() throws {
    let pipe = try FileDescriptor.pipe(options: .closeOnExec)
    let reader = OwnedFileDescriptor(takingOwnershipOf: pipe.readEnd)
    var writer = OwnedFileDescriptor(takingOwnershipOf: pipe.writeEnd)
    #expect(try !StartProtocol.waitReadable(reader, timeout: .zero))
    try writer.close()
    #expect(try StartProtocol.waitReadable(reader, timeout: .zero))
    let closed = OwnedFileDescriptor()
    #expect(throws: Errno.badFileDescriptor) { try StartProtocol.waitReadable(closed, timeout: .zero) }
}

@Test func hookPollReportsBothReadyDirections() throws {
    let pipe = try FileDescriptor.pipe(options: .closeOnExec)
    let reader = OwnedFileDescriptor(takingOwnershipOf: pipe.readEnd)
    let writer = OwnedFileDescriptor(takingOwnershipOf: pipe.writeEnd)
    _ = try writer.withDescriptor { try Kernel.File.write($0, [UInt8(42)].span.bytes) }
    let events = try reader.withDescriptor { read in
        try writer.withDescriptor { write in
            try Kernel.Poll.wait(reading: read, writing: write, timeout: .zero)
        }
    }
    #expect(events.read.contains(.input))
    #expect(events.write.contains(.output))
}
