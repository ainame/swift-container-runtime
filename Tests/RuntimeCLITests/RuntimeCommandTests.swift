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

@Test(arguments: [["--help"], ["namespace-run", "--help"], ["ps", "--help"]])
func helpExitsSuccessfully(_ arguments: [String]) {
    do {
        var command = try RuntimeCommand.parseAsRoot(arguments)
        try command.run()
        Issue.record("Expected a help request")
    } catch {
        #expect(RuntimeCommand.exitCode(for: error) == .success)
        let help = RuntimeCommand.fullMessage(for: error)
        #expect(help.contains(arguments.first == "ps" ? "host ps" : "namespace-run"))
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
    ["ps"],
    ["ps", "--bad-option"],
    ["ps", "--format", "xml", "box"],
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

@Test func psForwardsOptionsAfterContainerId() throws {
    let command = try #require(RuntimeCommand.parseAsRoot(["ps", "--root", "/tmp/state", "box", "-e", "-o", "pid,args", "--sort=-pid"]) as? Ps)
    #expect(command.id == "box")
    #expect(command.globals.root == "/tmp/state")
    #expect(command.psArguments == ["-e", "-o", "pid,args", "--sort=-pid"])
    let json = try #require(RuntimeCommand.parseAsRoot(["ps", "--format", "json", "box"]) as? Ps)
    #expect(json.format == .json)
    let before = try #require(RuntimeCommand.parseAsRoot(["--root", "/tmp/parent", "ps", "box", "--root", "is-a-ps-argument"]) as? Ps)
    #expect(before.globals.root == "/tmp/parent")
    #expect(before.psArguments == ["--root", "is-a-ps-argument"])
}

@Test(arguments: [("1m", Int64(1048576)), ("1.5 MiB", 1572864), ("2KB", 2048), ("4096", 4096), ("-1", -1), ("0.5b", 0)])
func memoryUnitsMatchRunc(_ input: String, _ bytes: Int64) throws {
    #expect(try parseRAMBytes(input) == bytes)
}

@Test(arguments: ["-2", "10XB", "18446744073709551615", "nan", "infinity", "1mbad"])
func rejectsInvalidMemoryUnits(_ input: String) {
    #expect(throws: ValidationError.self) { try parseRAMBytes(input) }
}

@Test func updateParsesSignedAndUnsignedResourceFlags() throws {
    let command = try #require(RuntimeCommand.parseAsRoot(["update", "--memory", "-1", "--cpu-quota", "-1", "--cpu-share", "1024", "--pids-limit", "-1", "box"]) as? Update)
    #expect(command.memory == "-1")
    #expect(command.cpuQuota == "-1")
    #expect(command.cpuShares == "1024")
    #expect(command.pidsLimit == -1)
    _ = try command.request()
}

@Test func parsesLifecycleRetentionAndPIDFiles() throws {
    let run = try #require(RuntimeCommand.parseAsRoot([
        "run", "--keep", "--pid-file", "relative.pid", "box",
    ]) as? Run)
    #expect(run.keep)
    #expect(run.pidFile == "relative.pid")
    let create = try #require(RuntimeCommand.parseAsRoot([
        "create", "--pid-file", "/tmp/init.pid", "box",
    ]) as? Create)
    #expect(create.pidFile == "/tmp/init.pid")
}


@Test func execStopsParsingAtTheContainerID() throws {
    let command = try #require(RuntimeCommand.parseAsRoot([
        "exec", "--root", "/tmp/state", "-e", "VALUE=hello", "--cwd", "/tmp", "-u", "1000:1000",
        "-d", "--pid-file", "exec.pid", "box", "/bin/echo", "--help", "--root", "workload",
    ]) as? Exec)
    #expect(command.globals.root == "/tmp/state")
    #expect(command.env == ["VALUE=hello"])
    #expect(command.cwd == "/tmp")
    #expect(command.user == "1000:1000")
    #expect(command.detach)
    #expect(command.pidFile == "exec.pid")
    #expect(command.id == "box")
    #expect(command.arguments == ["/bin/echo", "--help", "--root", "workload"])
}

@Test(arguments: [["exec"], ["exec", "box"], ["exec", "box", ""], ["exec", "--tty", "box", "/bin/sh"]])
func rejectsUnsupportedOrIncompleteExec(_ arguments: [String]) {
    #expect(throws: (any Error).self) { _ = try RuntimeCommand.parseAsRoot(arguments) }
}


@Test(arguments: ["sh", "bin/sh", "./sh"])
func execAcceptsBareAndRelativeExecutables(_ executable: String) throws {
    let command = try #require(RuntimeCommand.parseAsRoot(["exec", "box", executable, "-c"]) as? Exec)
    #expect(command.arguments == [executable, "-c"])
}

@Test func execParsesGroupsAndNoNewPrivileges() throws {
    let command = try #require(RuntimeCommand.parseAsRoot([
        "exec", "-g", "3000", "--additional-gids", "2000", "-g", "3000", "--no-new-privs", "box", "id", "-g", "1",
    ]) as? Exec)
    #expect(command.additionalGids == [3000, 2000, 3000])
    #expect(command.noNewPrivs)
    #expect(command.arguments == ["id", "-g", "1"])
    let plain = try #require(RuntimeCommand.parseAsRoot(["exec", "box", "id"]) as? Exec)
    #expect(plain.additionalGids.isEmpty)
    #expect(!plain.noNewPrivs)
    #expect(plain.cap.isEmpty)
    #expect(!plain.ignorePaused)
}

@Test func execParsesIgnorePausedBeforeIDOnly() throws {
    let command = try #require(RuntimeCommand.parseAsRoot(["exec", "--ignore-paused", "box", "true"]) as? Exec)
    #expect(command.ignorePaused)
    let workload = try #require(RuntimeCommand.parseAsRoot(["exec", "box", "echo", "--ignore-paused"]) as? Exec)
    #expect(!workload.ignorePaused)
    #expect(workload.arguments == ["echo", "--ignore-paused"])
}

@Test func execParsesRepeatedCapabilities() throws {
    let command = try #require(RuntimeCommand.parseAsRoot([
        "exec", "-c", "CAP_KILL", "--cap", "CAP_CHOWN", "-c", "CAP_KILL", "box", "id", "-c", "x",
    ]) as? Exec)
    #expect(command.cap == ["CAP_KILL", "CAP_CHOWN", "CAP_KILL"])
    #expect(command.arguments == ["id", "-c", "x"])
}

@Test(arguments: [
    ["exec", "-g", "-1", "box", "id"],
    ["exec", "-g", "4294967296", "box", "id"],
    ["exec", "--additional-gids", "x", "box", "id"],
    ["exec", "--no-new-privs=false", "box", "id"],
])
func rejectsInvalidExecGroupsAndPrivilegeValues(_ arguments: [String]) {
    #expect(throws: (any Error).self) { _ = try RuntimeCommand.parseAsRoot(arguments) }
}

@Test func execProcessJSONNeedsOnlyAnID() throws {
    let command = try #require(RuntimeCommand.parseAsRoot(["exec", "-p", "process.json", "box"]) as? Exec)
    #expect(command.processFile == "process.json")
    #expect(command.arguments.isEmpty)
}

@Test func parsesPreserveFDsBeforeTheContainerID() throws {
    #expect(try #require(RuntimeCommand.parseAsRoot(["run", "box"]) as? Run).preserveFDs == 0)
    #expect(try #require(RuntimeCommand.parseAsRoot(["create", "box"]) as? Create).preserveFDs == 0)
    #expect(try #require(RuntimeCommand.parseAsRoot(["exec", "box", "true"]) as? Exec).preserveFDs == 0)
    #expect(try #require(RuntimeCommand.parseAsRoot(["run", "--preserve-fds", "2", "box"]) as? Run).preserveFDs == 2)
    #expect(try #require(RuntimeCommand.parseAsRoot(["create", "--preserve-fds=2", "box"]) as? Create).preserveFDs == 2)
    let exec = try #require(RuntimeCommand.parseAsRoot(["exec", "--preserve-fds", "3", "-p", "p.json", "box"]) as? Exec)
    #expect(exec.preserveFDs == 3)
    #expect(exec.processFile == "p.json")
    // After the ID it belongs to the workload.
    let workload = try #require(RuntimeCommand.parseAsRoot(["exec", "box", "echo", "--preserve-fds", "3"]) as? Exec)
    #expect(workload.preserveFDs == 0)
    #expect(workload.arguments == ["echo", "--preserve-fds", "3"])
    let largest = try #require(RuntimeCommand.parseAsRoot(["run", "--preserve-fds", "2147483644", "box"]) as? Run)
    #expect(largest.preserveFDs == 2_147_483_644)
}

@Test func parsesPidfdSocketBeforeTheContainerID() throws {
    #expect(try #require(RuntimeCommand.parseAsRoot(["run", "box"]) as? Run).pidfdSocket == nil)
    #expect(try #require(RuntimeCommand.parseAsRoot(["create", "box"]) as? Create).pidfdSocket == nil)
    #expect(try #require(RuntimeCommand.parseAsRoot(["exec", "box", "true"]) as? Exec).pidfdSocket == nil)
    let run = try #require(RuntimeCommand.parseAsRoot(["run", "--pidfd-socket", "/run/p.sock", "-d", "box"]) as? Run)
    #expect(run.pidfdSocket == "/run/p.sock")
    #expect(run.detach)
    let create = try #require(RuntimeCommand.parseAsRoot(["create", "--pidfd-socket=@abstract", "box"]) as? Create)
    #expect(create.pidfdSocket == "@abstract")
    // Kept with a process file: the socket is not part of the process JSON.
    let exec = try #require(
        RuntimeCommand.parseAsRoot(["exec", "--pidfd-socket", "rel.sock", "-p", "p.json", "box"]) as? Exec)
    #expect(exec.pidfdSocket == "rel.sock")
    #expect(exec.processFile == "p.json")
    // After the ID it belongs to the workload.
    let workload = try #require(RuntimeCommand.parseAsRoot(["exec", "box", "echo", "--pidfd-socket", "x"]) as? Exec)
    #expect(workload.pidfdSocket == nil)
    #expect(workload.arguments == ["echo", "--pidfd-socket", "x"])
}

@Test(arguments: [
    ["run", "--pidfd-socket", "", "box"],
    ["create", "--pidfd-socket", "/" + String(repeating: "a", count: 107), "box"],
    ["exec", "--pidfd-socket", "@" + String(repeating: "a", count: 108), "box", "true"],
    ["exec", "--pidfd-socket", "", "box", "true"],
    ["run", "box", "--pidfd-socket"],
])
func rejectsInvalidPidfdSockets(_ arguments: [String]) {
    do {
        _ = try RuntimeCommand.parseAsRoot(arguments)
        Issue.record("Expected parsing to reject \(arguments)")
    } catch {
        #expect(RuntimeCommand.exitCode(for: error) == .validationFailure)
    }
}

@Test(arguments: [
    ["run", "--preserve-fds", "-1", "box"],
    ["run", "--preserve-fds", "2147483645", "box"],
    ["create", "--preserve-fds", "abc", "box"],
    ["create", "--preserve-fds", "99999999999999999999", "box"],
    ["exec", "--preserve-fds=-1", "box", "true"],
    ["exec", "--preserve-fds", "2147483645", "box", "true"],
])
func rejectsInvalidPreserveFDs(_ arguments: [String]) {
    do {
        _ = try RuntimeCommand.parseAsRoot(arguments)
        Issue.record("Expected parsing to reject \(arguments)")
    } catch {
        #expect(RuntimeCommand.exitCode(for: error) == .validationFailure)
    }
}
