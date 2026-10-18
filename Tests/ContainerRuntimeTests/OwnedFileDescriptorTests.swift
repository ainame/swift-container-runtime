import SystemPackage
import Testing
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import ContainerRuntime

@Test func borrowedDescriptorsCommunicateThroughPipe() throws {
    let pipe = try FileDescriptor.pipe()
    let reader = OwnedFileDescriptor(takingOwnershipOf: pipe.readEnd)
    let writer = OwnedFileDescriptor(takingOwnershipOf: pipe.writeEnd)

    let written = try writer.withDescriptor { try $0.writeAll([UInt8(42)]) }
    let result = try reader.withDescriptor { try readByte(from: $0) }
    #expect(written == 1)
    #expect(result.count == 1)
    #expect(result.byte == 42)
}

@Test func explicitCloseInvalidatesBorrowAndIsIdempotent() throws {
    let pipe = try FileDescriptor.pipe()
    let reader = OwnedFileDescriptor(takingOwnershipOf: pipe.readEnd)
    var writer = OwnedFileDescriptor(takingOwnershipOf: pipe.writeEnd)

    try writer.close()
    try writer.close()
    do {
        _ = try writer.withDescriptor { $0.rawValue }
        Issue.record("A closed owner must reject borrowing")
    } catch {
        #expect(error as? Errno == .badFileDescriptor)
    }
    // EOF checks actual closure without inspecting a descriptor number that
    // another parallel test could already have reused.
    let result = try reader.withDescriptor { try readByte(from: $0) }
    #expect(result.count == 0)
}

@Test func relinquishedDescriptorRemainsUsable() throws {
    let pipe = try FileDescriptor.pipe()
    let reader = OwnedFileDescriptor(takingOwnershipOf: pipe.readEnd)
    let owner = OwnedFileDescriptor(takingOwnershipOf: pipe.writeEnd)
    let transferred = try owner.relinquish()
    defer { try? transferred.close() }

    let written = try transferred.writeAll([UInt8(73)])
    let result = try reader.withDescriptor { try readByte(from: $0) }
    #expect(written == 1)
    #expect(result.count == 1)
    #expect(result.byte == 73)
}

@Test func thrownErrorClosesConsumedOwner() throws {
    let pipe = try FileDescriptor.pipe()
    let reader = OwnedFileDescriptor(takingOwnershipOf: pipe.readEnd)
    let writer = OwnedFileDescriptor(takingOwnershipOf: pipe.writeEnd)
    do {
        try writeThenThrow(consume writer)
        Issue.record("Expected the injected failure")
    } catch DescriptorTestFailure.injected {
        // The writer has been destroyed by the time control returns here.
    }

    let payload = try reader.withDescriptor { try readByte(from: $0) }
    #expect(payload.count == 1)
    #expect(payload.byte == 91)
    let end = try reader.withDescriptor { try readByte(from: $0) }
    #expect(end.count == 0)
}

private enum DescriptorTestFailure: Error {
    case injected
}

private func writeThenThrow(_ writer: consuming OwnedFileDescriptor) throws {
    _ = try writer.withDescriptor { try $0.writeAll([UInt8(91)]) }
    throw DescriptorTestFailure.injected
}

private func readByte(from descriptor: FileDescriptor) throws -> (count: Int, byte: UInt8) {
    var readiness = pollfd(fd: descriptor.rawValue, events: Int16(POLLIN), revents: 0)
    let ready = unsafe poll(&readiness, 1, 1_000)
    try #require(ready == 1, "Pipe read timed out; writer cleanup may have failed")
    var byte: UInt8 = 0
    let count = try withUnsafeMutableBytes(of: &byte) { buffer in
        // The initialized byte stays borrowed for the synchronous read.
        unsafe try descriptor.read(into: buffer)
    }
    return (count, byte)
}

#if os(Linux)
@Test(arguments: [
    (Duration.zero, Int32(0)),
    (.milliseconds(-5), 0),
    (.nanoseconds(1), 1),
    (.milliseconds(100), 100),
    (.microseconds(1_500), 2),
    (.seconds(30), 30_000),
    (.seconds(Int64.max), .max),
])
func pollTimeoutRoundsUpAndClamps(_ duration: Duration, _ expected: Int32) {
    #expect(duration.pollTimeout == expected)
}

@Test func pollTimesOutOnAnIdlePipe() throws {
    let pipe = try FileDescriptor.pipe()
    let reader = OwnedFileDescriptor(takingOwnershipOf: pipe.readEnd)
    let writer = OwnedFileDescriptor(takingOwnershipOf: pipe.writeEnd)
    #expect(reader.poll(events: Int16(POLLIN), timeout: .milliseconds(10)) == 0)
    try writer.withDescriptor { _ = try $0.writeAll([1]) }
    #expect(reader.poll(events: Int16(POLLIN), timeout: .seconds(1)) & Int16(POLLIN) != 0)
}
#endif
