#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif
import SystemPackage
import Testing
@testable import ContainerRuntime

@Test func acceptsCountsWhoseFirstInternalDescriptorFitsInt32() throws {
    #expect(try PreservedDescriptors(count: 0) == PreservedDescriptors.none)
    #expect(try PreservedDescriptors(count: 0).firstInternal == 3)
    #expect(try PreservedDescriptors(count: 3).firstInternal == 6)
    #expect(try PreservedDescriptors(count: Int(Int32.max) - 3).firstInternal == Int32.max)
    #expect(try PreservedDescriptors(count: Int(Int32.max) - 3).closeRangeStart == UInt32(Int32.max))
    #expect(try PreservedDescriptors(count: 0).closeRangeStart == 3)
}

@Test(arguments: [-1, Int(Int32.max) - 2, Int(Int32.max), Int.max, Int.min])
func rejectsNegativeAndOverflowingCounts(_ count: Int) {
    #expect(throws: RuntimeError.self) { try PreservedDescriptors(count: count) }
}

@Test func verifiesEveryPreservedDescriptorInOrder() throws {
    var seen: [Int32] = []
    try PreservedDescriptors(count: 3).verify { seen.append($0); return 0 }
    #expect(seen == [3, 4, 5])
    try PreservedDescriptors.none.verify { _ in
        Issue.record("count 0 checks nothing")
        return nil
    }
}

@Test func reportsTheFirstMissingDescriptorAndStops() throws {
    var seen: [Int32] = []
    let error = try #require(throws: RuntimeError.self) {
        try PreservedDescriptors(count: Int(Int32.max) - 3).verify { seen.append($0); return $0 == 4 ? nil : 0 }
    }
    #expect(seen == [3, 4])
    #expect(error.description == "unable to stat preserved-fd 1 (of 2147483644): descriptor 4 is not open")
}

@Test func rejectsCloseOnExecDescriptorsAsRuntimeOwned() throws {
    var seen: [Int32] = []
    let error = try #require(throws: RuntimeError.self) {
        try PreservedDescriptors(count: 3).verify { seen.append($0); return $0 == 3 ? FD_CLOEXEC : 0 }
    }
    #expect(seen == [3])
    #expect(error.description == "preserved-fd 0 (of 3): descriptor 3 is close-on-exec; preserved descriptors must be inheritable")
}

@Test func readsRealDescriptorFlagsWithoutForking() throws {
    // A FilePath, not a literal, selects the safe overload rather than the
    // UnsafePointer<CChar> one.
    let path = FilePath("/dev/null")
    let descriptor = try FileDescriptor.open(path, .readOnly, options: .closeOnExec)
    defer { try? descriptor.close() }
    #expect(PreservedDescriptors.descriptorFlags(descriptor.rawValue).map { $0 & FD_CLOEXEC } == FD_CLOEXEC)
    #expect(PreservedDescriptors.descriptorFlags(-1) == nil)
}
