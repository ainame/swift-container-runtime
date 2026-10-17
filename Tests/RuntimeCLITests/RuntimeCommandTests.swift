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

@Test func parsesRunBundleAndID() throws {
    let command = try #require(RuntimeCommand.parseAsRoot(["run", "--bundle", "/srv/bundle", "box-1"]) as? Run)
    #expect(command.bundle == "/srv/bundle")
    #expect(command.id == "box-1")
    let short = try #require(RuntimeCommand.parseAsRoot(["run", "-b", "relative", "box"]) as? Run)
    #expect(short.bundle == "relative")
    // Like runc, the bundle defaults to the current directory.
    let defaulted = try #require(RuntimeCommand.parseAsRoot(["run", "box"]) as? Run)
    #expect(defaulted.bundle == ".")
}

@Test(arguments: [
    ["run"],
    ["run", "--bundle", "/srv/bundle"],
    ["run", "--bundle", "", "box"],
    ["run", "bad/id"],
    ["run", ".."],
    ["run", "box", "extra"],
])
func rejectsInvalidRunInvocation(_ arguments: [String]) {
    do {
        _ = try RuntimeCommand.parseAsRoot(arguments)
        Issue.record("Expected parsing to reject \(arguments)")
    } catch {
        #expect(RuntimeCommand.exitCode(for: error) == .validationFailure)
    }
}

@Test func rootOptionWorksBeforeOrAfterSubcommandLikeRunc() throws {
    let before = try #require(RuntimeCommand.parseAsRoot(["--root", "/tmp/state", "state", "box"]) as? State)
    #expect(before.globals.root == "/tmp/state")
    #expect(before.id == "box")
    let after = try #require(RuntimeCommand.parseAsRoot(["start", "--root", "/tmp/state", "box"]) as? Start)
    #expect(after.globals.root == "/tmp/state")
    let defaulted = try #require(RuntimeCommand.parseAsRoot(["delete", "box"]) as? Delete)
    #expect(defaulted.globals.root == "/run/swift-container-runtime")
    #expect(!defaulted.force)
}

@Test func parsesLifecycleCommands() throws {
    let create = try #require(RuntimeCommand.parseAsRoot(["create", "-b", "/srv/bundle", "box"]) as? Create)
    #expect(create.bundle == "/srv/bundle")
    #expect(create.id == "box")
    let defaultBundle = try #require(RuntimeCommand.parseAsRoot(["create", "box"]) as? Create)
    #expect(defaultBundle.bundle == ".")

    #expect(try (RuntimeCommand.parseAsRoot(["pause", "box"]) as? Pause)?.id == "box")
    #expect(try (RuntimeCommand.parseAsRoot(["resume", "box"]) as? Resume)?.id == "box")
    let kill = try #require(RuntimeCommand.parseAsRoot(["kill", "box"]) as? Kill)
    #expect(kill.signal == "TERM")
    let killNamed = try #require(RuntimeCommand.parseAsRoot(["kill", "box", "SIGKILL"]) as? Kill)
    #expect(killNamed.signal == "SIGKILL")
    let killNumbered = try #require(RuntimeCommand.parseAsRoot(["kill", "box", "9"]) as? Kill)
    #expect(killNumbered.signal == "9")

    let delete = try #require(RuntimeCommand.parseAsRoot(["delete", "-f", "box"]) as? Delete)
    #expect(delete.force)
    let deleteLong = try #require(RuntimeCommand.parseAsRoot(["delete", "--force", "box"]) as? Delete)
    #expect(deleteLong.force)

    let list = try #require(RuntimeCommand.parseAsRoot(["list"]) as? List)
    #expect(list.format == .table)
    #expect(!list.quiet)
    let json = try #require(RuntimeCommand.parseAsRoot(["list", "-f", "json", "-q"]) as? List)
    #expect(json.format == .json)
    #expect(json.quiet)

    let detached = try #require(RuntimeCommand.parseAsRoot(["run", "-d", "-b", "/srv/bundle", "box"]) as? Run)
    #expect(detached.detach)
    let foreground = try #require(RuntimeCommand.parseAsRoot(["run", "box"]) as? Run)
    #expect(!foreground.detach)
}

@Test(arguments: [
    ["create"],
    ["create", "bad/id"],
    ["create", "--bundle", "", "box"],
    ["start"],
    ["start", "a", "b"],
    ["state", ".."],
    ["kill", "box", "NOPE"],
    ["kill", "box", "TERM", "extra"],
    ["delete"],
    ["pause"],
    ["resume", "bad/id"],
    ["list", "--format", "xml"],
    ["list", "extra"],
    ["--root", "", "list"],
    ["state", "--root", "", "box"],
])
func rejectsInvalidLifecycleInvocation(_ arguments: [String]) {
    do {
        _ = try RuntimeCommand.parseAsRoot(arguments)
        Issue.record("Expected parsing to reject \(arguments)")
    } catch {
        #expect(RuntimeCommand.exitCode(for: error) == .validationFailure)
    }
}

@Test func rootHelpListsLifecycleCommands() {
    do {
        var command = try RuntimeCommand.parseAsRoot(["--help"])
        try command.run()
        Issue.record("Expected a help request")
    } catch {
        #expect(RuntimeCommand.exitCode(for: error) == .success)
        let help = RuntimeCommand.fullMessage(for: error)
        for name in ["create", "start", "state", "kill", "pause", "resume", "delete", "list", "run", "--root"] {
            #expect(help.contains(name), "missing \(name)")
        }
    }
}

@Test func runHelpDocumentsEducationalSubset() {
    do {
        var command = try RuntimeCommand.parseAsRoot(["run", "--help"])
        try command.run()
        Issue.record("Expected a help request")
    } catch {
        #expect(RuntimeCommand.exitCode(for: error) == .success)
        let help = RuntimeCommand.fullMessage(for: error)
        #expect(help.contains("--bundle"))
        // Help text wraps, so check a single word of the security disclaimer.
        #expect(help.contains("security"))
    }
}

@Test func parsesSignalZeroAsAProbe() throws {
    let command = try #require(RuntimeCommand.parseAsRoot(["kill", "box", "0"]) as? Kill)
    #expect(command.signal == "0")
}
