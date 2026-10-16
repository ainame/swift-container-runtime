import ArgumentParser
import ContainerRuntime
import SystemPackage

@main
struct RuntimeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-container-runtime",
        abstract: "An educational Linux container runtime.",
        discussion: "Educational subset of an OCI runtime; not a security sandbox.",
        subcommands: [
            Create.self, Start.self, State.self, Kill.self, Delete.self, List.self, Run.self, NamespaceRun.self,
        ]
    )

    @OptionGroup var globals: GlobalOptions
}

/// Options accepted before or after the subcommand name, like runc's `--root`.
struct GlobalOptions: ParsableArguments {
    @Option(help: ArgumentHelp("Directory holding container state.", valueName: "path"))
    var root = ContainerLifecycle.defaultRoot

    func validate() throws {
        guard !root.isEmpty, !root.utf8.contains(0) else {
            throw ValidationError("--root must be non-empty and contain no NUL")
        }
    }

    func lifecycle() throws -> ContainerLifecycle {
        try ContainerLifecycle(root: root)
    }
}

private func validatedID(_ id: String) throws -> ContainerID {
    do {
        return try ContainerID(id)
    } catch {
        throw ValidationError(String(describing: error))
    }
}

private func validateBundle(_ bundle: String) throws {
    guard !bundle.isEmpty, !bundle.utf8.contains(0) else {
        throw ValidationError("bundle path must be non-empty and contain no NUL")
    }
}

/// Prints a runtime failure and exits with `status`: 1 for lifecycle
/// commands as in runc, 125 for `run` so it stays distinct from workload exits.
private func failure(_ error: any Error, status: Int32 = 1) -> ExitCode {
    RuntimeDiagnostics.writeError("swift-container-runtime: \(error)")
    return ExitCode(status)
}

struct Create: ParsableCommand {
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

    @Argument(help: "Container ID.")
    var id: String

    mutating func validate() throws {
        try validateBundle(bundle)
        _ = try validatedID(id)
    }

    mutating func run() throws {
        do {
            try globals.lifecycle().create(id: ContainerID(id), plan: OCIRunPlan.load(bundle: FilePath(bundle)))
        } catch {
            throw failure(error)
        }
    }
}

struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Execute the workload of a created container.",
        discussion: "Succeeds only after the workload's execve succeeded. A container starts at most once."
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Container ID.")
    var id: String

    mutating func validate() throws {
        _ = try validatedID(id)
    }

    mutating func run() throws {
        do {
            try globals.lifecycle().start(id: ContainerID(id))
        } catch {
            throw failure(error)
        }
    }
}

struct State: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "state",
        abstract: "Print the OCI state of a container as JSON.",
        discussion: "Fields: ociVersion, id, pid (0 unless created or running), status "
            + "(creating, created, running, or stopped), bundle, rootfs, created, and annotations when present."
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Container ID.")
    var id: String

    mutating func validate() throws {
        _ = try validatedID(id)
    }

    mutating func run() throws {
        let json: String
        do {
            json = try globals.lifecycle().state(id: ContainerID(id)).stateJSON()
        } catch {
            throw failure(error)
        }
        print(json)
    }
}

struct Kill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kill",
        abstract: "Send a signal (default TERM) to the init of a created or running container.",
        discussion: "SIGNAL is a name such as KILL or SIGKILL, or a number. "
            + "In a PID namespace the init is PID 1, which ignores signals it has no handler for, except KILL and STOP."
    )

    @OptionGroup var globals: GlobalOptions

    @Argument(help: "Container ID.")
    var id: String

    @Argument(help: "Signal name or number.")
    var signal = "TERM"

    mutating func validate() throws {
        _ = try validatedID(id)
        do {
            _ = try SignalName.parse(signal)
        } catch {
            throw ValidationError(String(describing: error))
        }
    }

    mutating func run() throws {
        do {
            try globals.lifecycle().kill(id: ContainerID(id), signal: SignalName.parse(signal))
        } catch {
            throw failure(error)
        }
    }
}

struct Delete: ParsableCommand {
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
        _ = try validatedID(id)
    }

    mutating func run() throws {
        do {
            try globals.lifecycle().delete(id: ContainerID(id), force: force)
        } catch {
            throw failure(error)
        }
    }
}

enum ListFormat: String, ExpressibleByArgument, CaseIterable {
    case table, json
}

struct List: ParsableCommand {
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
                RuntimeDiagnostics.writeError("swift-container-runtime: \(warning)")
            }
            if quiet {
                output = reports.map { $0.id + "\n" }.joined()
            } else if format == .json {
                output = try ContainerStateReport.listJSON(reports) + "\n"
            } else {
                output = ContainerStateReport.table(reports)
            }
        } catch {
            throw failure(error)
        }
        print(output, terminator: "")
    }
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Create and start a container.",
        discussion: "Supports an educational subset of config.json and rejects anything else. "
            + "In the foreground it exits with the workload's status and removes the container state. "
            + "With --detach it returns after the workload started and keeps the state for state, kill, and delete. "
            + "There are no capability, seccomp, cgroup, or user-namespace controls, so this is not a security boundary."
    )

    @OptionGroup var globals: GlobalOptions

    @Option(name: [.customShort("b"), .long], help: "Path to the OCI bundle directory.")
    var bundle = "."

    @Flag(name: [.customShort("d"), .long], help: "Return once the workload has started.")
    var detach = false

    @Argument(help: "Container ID.")
    var id: String

    mutating func validate() throws {
        try validateBundle(bundle)
        _ = try validatedID(id)
    }

    mutating func run() throws {
        let status: Int32
        do {
            status = try globals.lifecycle().run(
                id: ContainerID(id), plan: OCIRunPlan.load(bundle: FilePath(bundle)), detach: detach
            )
        } catch {
            throw failure(error, status: 125)
        }
        // Keep this outside the catch: a workload may itself choose exit 125.
        throw ExitCode(status)
    }
}

struct NamespaceRun: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "namespace-run",
        abstract: "Run a command in new UTS, PID, and mount namespaces.",
        discussion: "Shares the caller's filesystem, network, user identity, and privileges. "
            + "Use -- before the absolute executable path."
    )

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
        let status: Int32
        do {
            status = try NamespaceCommand(hostname: hostname, arguments: workloadArguments).run()
        } catch {
            RuntimeDiagnostics.writeError("swift-container-runtime: \(error)")
            throw ExitCode(125)
        }
        // Keep this outside the catch: a workload may itself choose exit 125.
        throw ExitCode(status)
    }
}
