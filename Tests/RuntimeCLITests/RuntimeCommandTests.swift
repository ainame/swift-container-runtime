import ArgumentParser
import Testing
@testable import RuntimeCLI

@Test func parsesNamespaceOptionsAndPreservesWorkloadArguments() throws {
    let command = try #require(
        RuntimeCommand.parseAsRoot([
            "namespace-run", "--hostname", "outer", "--", "/bin/sh", "-c",
            "printf '%s' \"$1\"", "--hostname", "inner", "", "--", "é",
        ]) as? NamespaceRun
    )
    #expect(command.hostname == "outer")
    #expect(command.workloadArguments == [
        "/bin/sh", "-c", "printf '%s' \"$1\"", "--hostname", "inner", "", "--", "é",
    ])
}

@Test func preservesWorkloadHelpAndHostnameOptions() throws {
    let command = try #require(
        RuntimeCommand.parseAsRoot(["namespace-run", "--", "/bin/echo", "--hostname", "inside", "-h"])
            as? NamespaceRun
    )
    #expect(command.hostname == "swiftbox")
    #expect(command.workloadArguments == ["/bin/echo", "--hostname", "inside", "-h"])
}

@Test(arguments: [
    ["namespace-run"],
    ["namespace-run", "--"],
    ["namespace-run", "/bin/echo", "missing-separator"],
    ["namespace-run", "--", "sh"],
    ["namespace-run", "--hostname"],
    ["namespace-run", "--hostname", "", "--", "/bin/true"],
    ["namespace-run", "--hostname", String(repeating: "é", count: 33), "--", "/bin/true"],
    ["namespace-run", "--", "/bin/echo", "bad\0argument"],
    ["unknown-command"],
])
func rejectsInvalidInvocation(_ arguments: [String]) {
    do {
        _ = try RuntimeCommand.parseAsRoot(arguments)
        Issue.record("Expected parsing to reject \(arguments)")
    } catch {
        #expect(RuntimeCommand.exitCode(for: error) == .validationFailure)
    }
}

@Test(arguments: [["--help"], ["namespace-run", "--help"]])
func helpExitsSuccessfully(_ arguments: [String]) {
    do {
        var command = try RuntimeCommand.parseAsRoot(arguments)
        try command.run()
        Issue.record("Expected a help request")
    } catch {
        #expect(RuntimeCommand.exitCode(for: error) == .success)
        let help = RuntimeCommand.fullMessage(for: error)
        #expect(help.contains("namespace-run"))
        if arguments.first == "namespace-run" {
            #expect(help.contains("--hostname"))
            #expect(help.contains("privileges"))
        }
    }
}
