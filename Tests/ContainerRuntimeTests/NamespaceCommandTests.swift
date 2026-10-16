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

#if os(Linux)
@Test func rejectsMultithreadedCallerBeforeForking() throws {
    // Swift Testing's concurrent executor supplies a real multithreaded caller.
    // Check that premise explicitly rather than risk exercising the launch path.
    try #require(launchThreadCount() > 1)
    let command = try NamespaceCommand(hostname: "must-not-launch", arguments: ["/bin/true"])
    do {
        _ = try command.run()
        Issue.record("Expected the multithreaded caller to be rejected")
    } catch let error as RuntimeError {
        #expect(error.description.contains("requires a single-threaded process"))
    }
}
#else
@Test func reportsUnsupportedPlatform() throws {
    let command = try NamespaceCommand(hostname: "swiftbox", arguments: ["/bin/true"])
    #expect(throws: RuntimeError.self) { try command.run() }
}
#endif
