import Testing
@testable import ContainerRuntime

@Test func acceptsAMatchingPIDAndPositiveCountAsGoAtoiParses() {
    #expect(SocketActivation(listenPID: "42", listenFDs: "2", processID: 42).count == 2)
    #expect(SocketActivation(listenPID: "+042", listenFDs: "+01", processID: 42).count == 1)
    #expect(SocketActivation(listenPID: "42", listenFDs: "2", processID: 42).environment == ["LISTEN_FDS=2", "LISTEN_PID=1"])
}

@Test(arguments: [
    (String?.none, String?.some("1")), ("42", nil), ("43", "1"), ("42", "0"), ("42", "-1"), ("42", "-0"),
    (" 42", "1"), ("42 ", "1"), ("42", " 1"), ("0x2a", "1"), ("42", "0x1"), ("", "1"), ("42", ""), ("+", "1"),
    ("42", "1_0"), ("42", "99999999999999999999"), ("99999999999999999999", "1"), ("4\u{0662}", "1"),
])
func ignoresAbsentMalformedMismatchedOrNonPositiveValues(_ pid: String?, _ fds: String?) {
    let activation = SocketActivation(listenPID: pid, listenFDs: fds, processID: 42)
    #expect(activation == .none)
    #expect(activation.environment.isEmpty)
}

@Test func placesExplicitDescriptorsAfterTheActivationRange() throws {
    let activation = SocketActivation(listenPID: "7", listenFDs: "2", processID: 7)
    #expect(try activation.preserving(1).count == 3)
    #expect(try activation.preserving(0).firstInternal == 5)
    #expect(try SocketActivation.none.preserving(4).count == 4)
    var seen: [Int32] = []
    try activation.preserving(1).verify { seen.append($0); return 0 }
    #expect(seen == [3, 4, 5])
}

@Test func rejectsCombinedCountsBeyondTheDescriptorRange() throws {
    let edge = SocketActivation(listenPID: "7", listenFDs: String(Int32.max - 4), processID: 7)
    #expect(try edge.preserving(1).firstInternal == Int32.max)
    #expect(throws: RuntimeError.self) { try edge.preserving(2) }
    let huge = SocketActivation(listenPID: "7", listenFDs: String(Int.max), processID: 7)
    #expect(throws: RuntimeError.self) { try huge.preserving(0) }
    #expect(throws: RuntimeError.self) { try huge.preserving(1) }
    // A negative explicit count is still rejected, not netted against activation.
    let some = SocketActivation(listenPID: "7", listenFDs: "3", processID: 7)
    #expect(throws: RuntimeError.self) { try some.preserving(-1) }
}

@Test func activationVariablesOverrideConfiguredOnesAndKeepTheRest() throws {
    let configured = ["PATH=/bin", "LISTEN_PID=99", "LISTEN_FDNAMES=web", "LISTEN_FDS=9", "A=1"]
    let merged = try OCIRunPlan.environment(configured + SocketActivation(listenPID: "5", listenFDs: "1", processID: 5).environment)
    #expect(merged == ["PATH=/bin", "LISTEN_FDNAMES=web", "A=1", "LISTEN_FDS=1", "LISTEN_PID=1"])
}
