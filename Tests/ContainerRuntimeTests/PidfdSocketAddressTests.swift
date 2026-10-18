import Testing
@testable import ContainerRuntime

@Test func acceptsFilesystemPathsUpToGoDialLimit() throws {
    let longest = String(repeating: "a", count: 107)
    let address = try UnixSocketAddress(longest)
    #expect(!address.isAbstract)
    #expect(address.sunPath == Array(longest.utf8) + [0])
    // The terminating NUL is part of the address length.
    #expect(address.sunPath.count == 108)
    #expect(try UnixSocketAddress("relative/pidfd.sock").sunPath.count == 20)
    #expect(try UnixSocketAddress("/run/pidfd.sock").path == "/run/pidfd.sock")
}

@Test func encodesAbstractNamesWithoutTerminator() throws {
    let address = try UnixSocketAddress("@runtime-pidfd")
    #expect(address.isAbstract)
    #expect(address.sunPath == [0] + Array("runtime-pidfd".utf8))
    #expect(address.sunPath.count == 14)
    let longest = try UnixSocketAddress("@" + String(repeating: "b", count: 107))
    #expect(longest.sunPath.count == 108)
}

@Test func classifiesRelativePaths() throws {
    // Only relative filesystem paths depend on the command's base directory.
    #expect(try UnixSocketAddress("pidfd.sock").isRelative)
    #expect(try UnixSocketAddress("../run/pidfd.sock").isRelative)
    #expect(try !UnixSocketAddress("/run/pidfd.sock").isRelative)
    #expect(try !UnixSocketAddress("@pidfd").isRelative)
}

@Test(arguments: [
    "",
    "/tmp/a\u{0}b",
    String(repeating: "a", count: 108),
    "/" + String(repeating: "a", count: 200),
    "@" + String(repeating: "b", count: 108),
])
func rejectsUnusableUnixSocketAddresses(_ path: String) {
    #expect(throws: RuntimeError.self) { try UnixSocketAddress(path) }
}

@Test func countsUTF8BytesForTheLimit() throws {
    // 53 two-byte scalars are 106 bytes; 54 exceed 107.
    _ = try UnixSocketAddress(String(repeating: "é", count: 53))
    #expect(throws: RuntimeError.self) { try UnixSocketAddress(String(repeating: "é", count: 54)) }
}
