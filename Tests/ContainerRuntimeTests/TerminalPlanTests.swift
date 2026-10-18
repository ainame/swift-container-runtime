import Testing
@testable import ContainerRuntime

private func terminalProcess(_ fields: String) throws -> OCIProcessPlan {
    try OCIProcessPlan(OCIConfiguration.decodeProcess(Array("{\"args\":[\"/bin/sh\"],\"cwd\":\"/\"\(fields)}".utf8)))
}

@Test func terminalAndConsoleSizeDecode() throws {
    let plan = try terminalProcess(#","terminal":true,"consoleSize":{"height":24,"width":80}"#)
    #expect(plan.terminal)
    #expect(plan.consoleSize?.height == 24)
    #expect(plan.consoleSize?.width == 80)
    #expect(try !terminalProcess("").terminal)
}

@Test(arguments: [#","consoleSize":{"height":0,"width":80}"#, #","consoleSize":{"height":24,"width":0}"#])
func consoleSizeWithAZeroDimensionIsNotApplied(_ fields: String) throws {
    #expect(try terminalProcess(#","terminal":true"# + fields).consoleSize == nil)
}

@Test(arguments: [
    #","consoleSize":{"height":65536,"width":80}"#, #","consoleSize":{"height":24}"#,
    #","consoleSize":{"height":24,"width":80,"depth":1}"#,
])
func invalidConsoleSizesAreRejected(_ fields: String) {
    #expect(throws: (any Error).self) { try terminalProcess(fields) }
}

@Test func consoleSocketAddressesNameTheirOption() {
    #expect {
        try UnixSocketAddress("", option: "--console-socket")
    } throws: { error in
        "\(error)".contains("--console-socket")
    }
}
