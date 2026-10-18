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
