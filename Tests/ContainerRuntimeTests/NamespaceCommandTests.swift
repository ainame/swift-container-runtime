import Testing
@testable import ContainerRuntime

@Test(arguments: ["", String(repeating: "x", count: 65), "bad\0name", String(repeating: "é", count: 33)])
func rejectsInvalidHostname(_ hostname: String) {
    #expect(throws: RuntimeError.self) {
        try NamespaceCommand(hostname: hostname, arguments: ["/bin/true"])
    }
}

@Test(arguments: [[], ["sh"], ["/bin/sh", "bad\0argument"]])
func rejectsInvalidArguments(_ arguments: [String]) {
    #expect(throws: RuntimeError.self) {
        try NamespaceCommand(hostname: "swiftbox", arguments: arguments)
    }
}

@Test func preservesArgumentsWithoutShellInterpretation() throws {
    let arguments = ["/bin/echo", "a b", "$(hostname)", "", "é"]
    let command = try NamespaceCommand(hostname: String(repeating: "x", count: 64), arguments: arguments)
    #expect(command.arguments == arguments)
    #expect(command.hostname.utf8.count == 64)
}
