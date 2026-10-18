import Testing
@testable import ContainerRuntime

@Test(arguments: [
    (Int32(0), nil, "exit status 0"),
    (1, nil, "exit status 1"),
    (3, nil, "exit status 3"),
    (128, nil, "exit status 128"),
    (129, Int32(1), "killed by signal 1 (status 129)"),
    (137, 9, "killed by signal 9 (status 137)"),
    (143, 15, "killed by signal 15 (status 143)"),
    (192, 64, "killed by signal 64 (status 192)"),
    (193, nil, "exit status 193"),
    (255, nil, "exit status 255"),
])
func describesShellStatus(_ value: Int32, _ signal: Int32?, _ description: String) {
    let status = ExitStatus(shellStatus: value)
    #expect(status.shellStatus == value)
    #expect(status.signal == signal)
    #expect(status.isSuccess == (value == 0))
    #expect((status == .success) == (value == 0))
    #expect(status.description == description)
}

@Test func successfulExitStatusHasValueSemantics() {
    #expect(ExitStatus.success.shellStatus == 0)
    #expect(ExitStatus.success.isSuccess)
    #expect(ExitStatus.success.signal == nil)
    #expect(ExitStatus.success.description == "exit status 0")
    #expect(Set([ExitStatus.success, ExitStatus(shellStatus: 0), ExitStatus(shellStatus: 1)]).count == 2)
}
