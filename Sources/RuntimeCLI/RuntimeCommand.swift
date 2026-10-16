import ArgumentParser
import ContainerRuntime

@main
struct RuntimeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-container-runtime",
        abstract: "An educational Linux container runtime.",
        discussion: "Experimental namespace lab; not yet an OCI runtime or a security sandbox.",
        subcommands: [NamespaceRun.self]
    )
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
