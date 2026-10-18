import ArgumentParser
import ContainerRuntime
import SystemPackage

@main
struct RuntimeCommand: RuntimeLoggingCommand {
    static let configuration = CommandConfiguration(
        commandName: "srunc",
        abstract: "An educational Linux container runtime.",
        discussion: "Educational subset of an OCI runtime; not a security sandbox.",
        version: VersionOutput.text,
        subcommands: [
            Create.self, Start.self, Exec.self, State.self, Kill.self, Pause.self, Resume.self, Delete.self, List.self, Ps.self, Update.self, Events.self,
            Spec.self, Features.self, Run.self, NamespaceRun.self,
        ]
    )

    @OptionGroup var globals: GlobalOptions

    @Flag(name: .customShort("v"), help: "Print the runtime version.")
    var shortVersion = false

    mutating func run() throws {
        guard shortVersion else { throw CleanExit.helpRequest(self) }
        print(VersionOutput.text)
    }
}

struct Create: RuntimeDescriptorCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a container whose workload waits for start.",
        discussion: "Sets up the namespaces, root filesystem, and init, then exits. "
            + "The workload inherits this command's stdin, stdout, and stderr, which the waiting init keeps open; "
            + "redirect them when capturing this command's output."
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: [.customShort("b"), .long], help: "Path to the OCI bundle directory.")
    var bundle = "."

    @Option(name: .customLong("pid-file"), help: "Write the host init PID atomically to this path.")
    var pidFile: String?

    @Flag(name: .customLong("no-new-keyring"), help: "Inherit the caller's session keyring for init and exec.")
    var noNewKeyring = false

    @OptionGroup var descriptors: DescriptorOptions

    @Argument(help: "Container ID.")
    var id: String

    mutating func validate() throws {
        try CommandValidation.bundle(bundle)
        try CommandValidation.pidFile(pidFile)
        _ = try CommandValidation.id(id)
    }

    mutating func run() throws {
        do {
            // Check caller descriptors before loading the plan can open any.
            try PreservedDescriptors(count: descriptors.preserveFDs).verify()
            try globals.lifecycle().create(
                id: ContainerID(id), plan: OCIRunPlan.load(bundle: FilePath(bundle)), pidFile: pidFile,
                preserveDescriptors: descriptors.preserveFDs, pidfdSocket: descriptors.pidfdSocket, noNewKeyring: noNewKeyring,
                consoleSocket: descriptors.consoleSocket)
        } catch {
            throw CommandFailure.report(error)
        }
    }
}

struct Start: RuntimeLoggingCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Execute the workload of a created container.",
        discussion: "Succeeds only after the workload's execve succeeded. A container starts at most once."
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Container ID.")
    var id: String

    mutating func validate() throws {
        _ = try CommandValidation.id(id)
    }

    mutating func run() throws {
        do {
            try globals.lifecycle().start(id: ContainerID(id))
        } catch {
            throw CommandFailure.report(error)
        }
    }
}

struct State: RuntimeLoggingCommand {
    static let configuration = CommandConfiguration(
        commandName: "state",
        abstract: "Print the OCI state of a container as JSON.",
        discussion: "Fields: ociVersion, id, pid (0 unless created, running, or paused), status "
            + "(creating, created, running, paused, or stopped), bundle, rootfs, created, and annotations when present."
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Container ID.")
    var id: String

    mutating func validate() throws {
        _ = try CommandValidation.id(id)
    }

    mutating func run() throws {
        let json: String
        do {
            json = try globals.lifecycle().state(id: ContainerID(id)).stateJSON()
        } catch {
            throw CommandFailure.report(error)
        }
        print(json)
    }
}

struct Kill: RuntimeLoggingCommand {
    static let configuration = CommandConfiguration(
        commandName: "kill",
        abstract: "Send a signal (default TERM) to the init of a created, running, or paused container.",
        discussion: "SIGNAL is a name such as KILL or SIGKILL, or a number. "
            + "SIGKILL also kills the cgroup subtree when the container shares a PID namespace. "
            + "Other signals target init, including with the compatibility flag --all."
    )

    @OptionGroup var globals: GlobalOptions

    @Flag(name: [.customShort("a"), .long], help: "Compatibility flag; also succeed when the container is already stopped.")
    var all = false

    @Argument(help: "Container ID.")
    var id: String

    @Argument(help: "Signal name or number.")
    var signal = "TERM"

    mutating func validate() throws {
        _ = try CommandValidation.id(id)
        do {
            _ = try SignalName.parse(signal)
        } catch {
            throw ValidationError(String(describing: error))
        }
    }

    mutating func run() throws {
        do {
            try globals.lifecycle().kill(id: ContainerID(id), signal: SignalName.parse(signal), all: all)
        } catch {
            throw CommandFailure.report(error)
        }
    }
}

struct Pause: RuntimeLoggingCommand {
    static let configuration = CommandConfiguration(commandName: "pause", abstract: "Freeze all processes in a created or running container.")
    @OptionGroup var globals: GlobalOptions
    @Argument(help: "Container ID.") var id: String

    mutating func validate() throws { _ = try CommandValidation.id(id) }

    mutating func run() throws {
        do { try globals.lifecycle().pause(id: ContainerID(id)) }
        catch { throw CommandFailure.report(error) }
    }
}

struct Resume: RuntimeLoggingCommand {
    static let configuration = CommandConfiguration(commandName: "resume", abstract: "Thaw a paused container.")
    @OptionGroup var globals: GlobalOptions
    @Argument(help: "Container ID.") var id: String

    mutating func validate() throws { _ = try CommandValidation.id(id) }

    mutating func run() throws {
        do { try globals.lifecycle().resume(id: ContainerID(id)) }
        catch { throw CommandFailure.report(error) }
    }
}

struct Delete: RuntimeLoggingCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a stopped container's state.",
        discussion: "A created container's waiting init is killed first, as in runc. "
            + "--force also kills a running container's init with SIGKILL and waits for it."
    )

    @OptionGroup var globals: GlobalOptions

    @Flag(name: [.customShort("f"), .long], help: "Kill the init if it is still running.")
    var force = false

    @Argument(help: "Container ID.")
    var id: String

    mutating func validate() throws {
        _ = try CommandValidation.id(id)
    }

    mutating func run() throws {
        do {
            try globals.lifecycle().delete(id: ContainerID(id), force: force)
        } catch {
            throw CommandFailure.report(error)
        }
    }
}

enum ListFormat: String, ExpressibleByArgument, CaseIterable {
    case table, json
}

struct Ps: RuntimeLoggingCommand {
    static let configuration = CommandConfiguration(
        commandName: "ps", abstract: "List host processes belonging to a container.",
        discussion: "Options after the container ID are passed verbatim to host ps. The default is ps -ef."
    )
    // A passthrough child must decode its own root option: reusing the
    // parent's OptionGroup would reuse an already-decoded default and
    // leave --root after the subcommand unconsumed.
    @ParentCommand var parent: RuntimeCommand
    @OptionGroup var logging: PassthroughLoggingOptions
    @Option(name: .customLong("root"), help: "Directory holding container state.")
    var stateRoot: String?
    var globals: GlobalOptions {
        var result = logging.applying(to: parent.globals)
        if let stateRoot { result.root = stateRoot }
        return result
    }
    @Option(name: [.customShort("f"), .long], help: "Output format: table or json.")
    var format: ListFormat = .table
    // Capture the ID and trailing options together: the first positional
    // value stops option parsing, just as runc's StopOnNthArg does.
    @Argument(parsing: .captureForPassthrough, help: "Container ID followed by host ps options.")
    var operands: [String] = []
    private var positionals: ArraySlice<String> {
        operands.first == "--" ? operands.dropFirst() : operands[...]
    }
    var id: String { positionals.first ?? "" }
    var psArguments: [String] { Array(positionals.dropFirst()) }

    mutating func validate() throws {
        if operands.first != "--" {
            if id == "--help" || id == "-h" { throw CleanExit.helpRequest(Self.self) }
            if id.hasPrefix("-") { throw ValidationError("unknown option \(id) before container ID") }
        }
        try globals.validate()
        _ = try CommandValidation.id(id)
    }

    mutating func run() throws {
        do {
            let lifecycle = try globals.lifecycle()
            if format == .json {
                let pids = try lifecycle.processIDs(id: ContainerID(id))
                print(pids.isEmpty ? "null" : "[" + pids.map(String.init).joined(separator: ",") + "]")
            } else {
                print(try lifecycle.processTable(id: ContainerID(id), arguments: psArguments), terminator: "")
            }
        } catch { throw CommandFailure.report(error) }
    }
}

struct List: RuntimeLoggingCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List containers under the state root.",
        discussion: "The table has the columns ID, PID, STATUS, BUNDLE, CREATED, and OWNER. "
            + "JSON output is one array of state objects, each with an owner field."
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: [.customShort("f"), .long], help: "Output format: table or json.")
    var format: ListFormat = .table

    @Flag(name: [.customShort("q"), .long], help: "Print only container IDs.")
    var quiet = false

    mutating func run() throws {
        let output: String
        do {
            let (reports, warnings) = try globals.lifecycle().list()
            for warning in warnings {
                RuntimeDiagnostics.writeError("srunc: \(warning)")
            }
            if quiet {
                output = reports.map { $0.id + "\n" }.joined()
            } else if format == .json {
                output = try ContainerStateReport.listJSON(reports) + "\n"
            } else {
                output = ContainerStateReport.table(reports)
            }
        } catch {
            throw CommandFailure.report(error)
        }
        print(output, terminator: "")
    }
}

struct Run: RuntimeDescriptorCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Create and start a container.",
        discussion: "Supports an educational subset of config.json and rejects anything else. "
            + "In the foreground it exits with the workload's status and removes the container state. "
            + "With --detach it returns after the workload started and keeps the state for state, kill, and delete. "
            + "A terminal (process.terminal) needs --detach and --console-socket; foreground terminals and rootless "
            + "operation are not implemented; this is not a security boundary."
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: [.customShort("b"), .long], help: "Path to the OCI bundle directory.")
    var bundle = "."

    @Flag(name: [.customShort("d"), .long], help: "Return once the workload has started.")
    var detach = false

    @Flag(help: "Retain the container state after foreground exit; remove it with delete.")
    var keep = false

    @Option(name: .customLong("pid-file"), help: "Write the host init PID atomically to this path.")
    var pidFile: String?

    @Flag(name: .customLong("no-new-keyring"), help: "Inherit the caller's session keyring for init and exec.")
    var noNewKeyring = false

    @OptionGroup var descriptors: DescriptorOptions

    @Argument(help: "Container ID.")
    var id: String

    mutating func validate() throws {
        try CommandValidation.bundle(bundle)
        try CommandValidation.pidFile(pidFile)
        _ = try CommandValidation.id(id)
    }

    mutating func run() throws {
        let status: ExitStatus
        do {
            try PreservedDescriptors(count: descriptors.preserveFDs).verify()
            status = try globals.lifecycle().run(
                id: ContainerID(id), plan: OCIRunPlan.load(bundle: FilePath(bundle)), detach: detach, keep: keep, pidFile: pidFile,
                preserveDescriptors: descriptors.preserveFDs, pidfdSocket: descriptors.pidfdSocket, noNewKeyring: noNewKeyring,
                consoleSocket: descriptors.consoleSocket
            )
        } catch {
            throw CommandFailure.report(error, status: 125)
        }
        // Keep this outside the catch: a workload may itself choose exit 125.
        throw ExitCode(status.shellStatus)
    }
}

struct NamespaceRun: RuntimeLoggingCommand {
    static let configuration = CommandConfiguration(
        commandName: "namespace-run",
        abstract: "Run a command in new UTS, PID, and mount namespaces.",
        discussion: "Shares the caller's filesystem, network, user identity, and privileges. "
            + "Use -- before the absolute executable path."
    )

    @OptionGroup var globals: GlobalOptions

    @Option(help: "Hostname in the new UTS namespace.")
    var hostname = "swiftbox"

    @Argument(parsing: .postTerminator, help: "Absolute executable path followed by its arguments.")
    var workload: [String] = []

    var workloadArguments: [String] {
        workload
    }

    mutating func validate() throws {
        do {
            _ = try NamespaceCommand(hostname: hostname, arguments: workloadArguments)
        } catch {
            throw ValidationError(String(describing: error))
        }
    }

    mutating func run() throws {
        let status: ExitStatus
        do {
            status = try NamespaceCommand(hostname: hostname, arguments: workloadArguments).run()
        } catch {
            throw CommandFailure.report(error, status: 125)
        }
        // Keep this outside the catch: a workload may itself choose exit 125.
        throw ExitCode(status.shellStatus)
    }
}
