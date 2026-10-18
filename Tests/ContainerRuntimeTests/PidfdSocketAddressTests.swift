import Testing
@testable import ContainerRuntime

@Test func acceptsFilesystemPathsUpToGoDialLimit() throws {
    let longest = String(repeating: "a", count: 107)
    let address = try PidfdSocketAddress(longest)
    #expect(!address.isAbstract)
    #expect(address.sunPath == Array(longest.utf8) + [0])
    // The terminating NUL is part of the address length.
    #expect(address.sunPath.count == 108)
    #expect(try PidfdSocketAddress("relative/pidfd.sock").sunPath.count == 20)
    #expect(try PidfdSocketAddress("/run/pidfd.sock").path == "/run/pidfd.sock")
}

@Test func encodesAbstractNamesWithoutTerminator() throws {
    let address = try PidfdSocketAddress("@runtime-pidfd")
    #expect(address.isAbstract)
    #expect(address.sunPath == [0] + Array("runtime-pidfd".utf8))
    #expect(address.sunPath.count == 14)
    let longest = try PidfdSocketAddress("@" + String(repeating: "b", count: 107))
    #expect(longest.sunPath.count == 108)
}

@Test func classifiesRelativePaths() throws {
    // Only relative filesystem paths depend on the command's base directory.
    #expect(try PidfdSocketAddress("pidfd.sock").isRelative)
    #expect(try PidfdSocketAddress("../run/pidfd.sock").isRelative)
    #expect(try !PidfdSocketAddress("/run/pidfd.sock").isRelative)
    #expect(try !PidfdSocketAddress("@pidfd").isRelative)
}

@Test(arguments: [
    "",
    "/tmp/a\u{0}b",
    String(repeating: "a", count: 108),
    "/" + String(repeating: "a", count: 200),
    "@" + String(repeating: "b", count: 108),
])
func rejectsUnusablePidfdSocketAddresses(_ path: String) {
    #expect(throws: RuntimeError.self) { try PidfdSocketAddress(path) }
}

@Test func countsUTF8BytesForTheLimit() throws {
    // 53 two-byte scalars are 106 bytes; 54 exceed 107.
    _ = try PidfdSocketAddress(String(repeating: "é", count: 53))
    #expect(throws: RuntimeError.self) { try PidfdSocketAddress(String(repeating: "é", count: 54)) }
}
