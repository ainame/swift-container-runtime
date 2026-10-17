import ArgumentParser
import ContainerRuntime

/// Parse runtime options before the ID; everything after it belongs to the
/// workload, including flags such as --help, --env and --root.
struct Exec: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec", abstract: "Run another nonterminal process in a container.",
        discussion: "Inherits process settings from the source bundle. Options must precede the container ID. "
            + "Terminal, process JSON, additional groups, and descriptor handoff options are not implemented."
    )
    @ParentCommand var parent: RuntimeCommand
    @Option(name: .customLong("root"), help: "Directory holding container state.") var stateRoot: String?
    @Option(name: [.customShort("e"), .long], help: "Add or replace an environment entry NAME=value.") var env: [String] = []
    @Option(help: "Working directory inside the container.") var cwd: String?
    @Option(name: [.customShort("u"), .long], help: "Numeric uid[:gid] for the exec process.") var user: String?
    @Option(name: .customLong("pid-file"), help: "Write the host exec PID atomically to this path.") var pidFile: String?
    @Flag(name: [.customShort("d"), .long], help: "Return once exec succeeds.") var detach = false
    @Argument(parsing: .captureForPassthrough, help: "Container ID, absolute executable path, and its arguments.") var operands: [String] = []
    private var positionals: ArraySlice<String> { operands.first == "--" ? operands.dropFirst() : operands[...] }
    var id: String { positionals.first ?? "" }
    var arguments: [String] { Array(positionals.dropFirst()) }
    var globals: GlobalOptions {
        var result = parent.globals
        if let stateRoot { result.root = stateRoot }
        return result
    }

    mutating func validate() throws {
        if operands.first != "--" {
            if id == "--help" || id == "-h" { throw CleanExit.helpRequest(Self.self) }
            if id.hasPrefix("-") { throw ValidationError("unknown option \(id) before container ID") }
        }
        try globals.validate()
        _ = try validatedID(id)
        guard let executable = arguments.first, executable.hasPrefix("/") else {
            throw ValidationError("exec requires an absolute executable path after the container ID")
        }
        guard (arguments + env + [cwd, user, pidFile].compactMap { $0 }).allSatisfy({ !$0.utf8.contains(0) }) else {
            throw ValidationError("exec options and arguments must not contain NUL")
        }
    }

    mutating func run() throws {
        let status: Int32
        do {
            status = try globals.lifecycle().exec(
                id: ContainerID(id), arguments: arguments, environment: env, cwd: cwd, user: user,
                detach: detach, pidFile: pidFile)
        } catch { throw failure(error) }
        throw ExitCode(status)
    }
}
