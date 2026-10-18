#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SystemPackage
import Testing
@testable import ContainerRuntime

@Test func listsDirectoryEntriesByPathAndByDescriptor() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "kernel-list-\(UInt64.random(in: 0...UInt64.max))")
    try FileManager.default.createDirectory(at: root.appending(path: "child"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("x".utf8).write(to: root.appending(path: "file"))

    #expect(try Kernel.File.directoryEntries(atPath: root.path).sorted() == ["child", "file"])
    #expect(try Kernel.File.directoryEntries(atPath: root.path, onlyDirectories: true) == ["child"])
    let directory = try Kernel.File.open(root.path, .readOnly, options: .directory)
    #expect(try directory.directoryEntries().sorted() == ["child", "file"])
    #expect(throws: Errno.noSuchFileOrDirectory) { try Kernel.File.directoryEntries(atPath: root.path + "/missing") }
}

@Test func writesAndReadsThroughSpansAndArrays() throws {
    let pipe = try FileDescriptor.pipe()
    defer { try? pipe.readEnd.close(); try? pipe.writeEnd.close() }
    let payload: [UInt8] = Array("kernel".utf8)
    #expect(try Kernel.File.write(pipe.writeEnd, payload.span.bytes) == payload.count)
    #expect(try Kernel.File.read(pipe.readEnd, upTo: 3) == Array("ker".utf8))
    try pipe.writeEnd.close()
    #expect(try Kernel.File.readAll(pipe.readEnd, limit: 16) == Array("nel".utf8))
    #expect(try Kernel.File.read(pipe.readEnd, upTo: 3).isEmpty)
}

@Test func readAllStopsAtTheLimit() throws {
    let pipe = try FileDescriptor.pipe()
    defer { try? pipe.readEnd.close() }
    _ = try Kernel.File.write(pipe.writeEnd, [UInt8](repeating: 1, count: 32).span.bytes)
    try pipe.writeEnd.close()
    #expect(throws: Errno.fileTooLarge) { try Kernel.File.readAll(pipe.readEnd, limit: 16, chunkSize: 8) }
}

@Test func launchRecordsRoundTripThroughTheirEncoding() {
    let record = LaunchRecord(.failure, stage: 7, error: .notPermitted, detail: -1, value: Int64.max - 5)
    let encoded = record.encoded
    #expect(encoded.count == 24)
    #expect(encoded[0] == UInt8(LaunchRecord.Kind.failure.rawValue))
    let decoded = LaunchRecord(encoded: encoded)
    #expect(decoded.kind == LaunchRecord.Kind.failure.rawValue)
    #expect(decoded.stage == 7)
    #expect(decoded.error == .notPermitted)
    #expect(decoded.detail == -1)
    #expect(decoded.value == Int64.max - 5)
}

@Test func readsIntoStackStorageAtAnOffset() throws {
    let pipe = try FileDescriptor.pipe()
    defer { try? pipe.readEnd.close(); try? pipe.writeEnd.close() }
    _ = try Kernel.File.write(pipe.writeEnd, Array("ab".utf8).span.bytes)
    var buffer = InlineArray<4, UInt8>(repeating: 0)
    var span = buffer.mutableSpan
    #expect(try Kernel.File.read(pipe.readEnd, into: &span, from: 1) == 2)
    #expect(buffer[0] == 0 && buffer[1] == UInt8(ascii: "a") && buffer[2] == UInt8(ascii: "b") && buffer[3] == 0)
}
