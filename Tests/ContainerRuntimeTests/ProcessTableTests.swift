import Testing
@testable import ContainerRuntime

@Test(arguments: [
    ("UID PID CMD\nroot 12 init\nuser 18 child\nroot 99 other\n", "UID PID CMD\nroot 12 init\nuser 18 child\n"),
    ("  PID COMMAND\n   12 init\n   18 child with spaces\n   99 other\n", "  PID COMMAND\n   12 init\n   18 child with spaces\n"),
    ("USER COMMAND PID\nroot init 12\nroot other 99\n", "USER COMMAND PID\nroot init 12\n"),
])
func filtersHostPsWhilePreservingLayout(_ output: String, _ expected: String) throws {
    #expect(try ProcessTable.filter(output, pids: [12, 18]) == expected)
}

@Test(arguments: ["COMMAND\ninit\n", "PID COMMAND\nnot-a-pid init\n", "USER PID COMMAND\nroot\n", ""])
func rejectsPsOutputWithoutUsablePidColumn(_ output: String) {
    #expect(throws: RuntimeError.self) { try ProcessTable.filter(output, pids: [12]) }
}

@Test func emptyPidSetStillPrintsHeader() throws {
    #expect(try ProcessTable.filter("PID CMD\n12 init\n", pids: []) == "PID CMD\n")
}
