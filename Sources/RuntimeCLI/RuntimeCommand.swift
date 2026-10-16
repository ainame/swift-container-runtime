import ArgumentParser
import ContainerRuntime
import SystemPackage

@main
struct RuntimeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-container-runtime",
        abstract: "An educational Linux container runtime.",
        discussion: "Educational subset of an OCI runtime; not a security sandbox.",
        subcommands: [Run.self, NamespaceRun.self]
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run an OCI bundle in the foreground and exit with its status.",
        discussion: "Supports an educational subset of config.json and rejects anything else. "
            + "No lifecycle state is kept and the ID is only validated. "
            + "There are no capability, seccomp, cgroup, or user-namespace controls, so this is not a security boundary."
    )

    @Option(name: [.customShort("b"), .long], help: "Path to the OCI bundle directory.")
    var bundle = "."

    @Argument(help: "Container ID.")
    var id: String

    mutating func validate() throws {
        guard !bundle.isEmpty, !bundle.utf8.contains(0) else {
            throw ValidationError("bundle path must be non-empty and contain no NUL")
        }
        do {
            _ = try ContainerID(id)
        } catch {
            throw ValidationError(String(describing: error))
        }
    }

    mutating func run() throws {
        let status: Int32
        do {
            status = try OCIRunPlan.load(bundle: FilePath(bundle)).run()
        } catch {
            RuntimeDiagnostics.writeError("swift-container-runtime: \(error)")
            throw ExitCode(125)
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
