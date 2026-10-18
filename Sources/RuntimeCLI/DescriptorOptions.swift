import ArgumentParser

/// Caller descriptor inheritance and process-handle handoff, shared by all launches.
struct DescriptorOptions: ParsableArguments {
    @Option(name: .customLong("preserve-fds"), help: "Pass caller descriptors 3 through 2+N to the workload at the same numbers. They must be open and not close-on-exec; their type is not checked.")
    var preserveFDs = 0

    @Option(name: .customLong("pidfd-socket"), help: "Send a pidfd for the new process, with a runc-compatible label, to the AF_UNIX stream listener at this path (or @abstract name).")
    var pidfdSocket: String?

    @Option(name: .customLong("console-socket"), help: "With process.terminal, send the new terminal's master to the AF_UNIX stream listener at this path (or @abstract name). Requires a detached process.")
    var consoleSocket: String?

    func validate() throws {
        try CommandValidation.socketAddress(pidfdSocket, option: "--pidfd-socket")
        try CommandValidation.socketAddress(consoleSocket, option: "--console-socket")
        _ = try CommandValidation.preservedDescriptors(preserveFDs)
    }
}
