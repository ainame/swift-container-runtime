import ArgumentParser
import ContainerRuntime

/// Parse runtime options before the ID; everything after it belongs to the
/// workload, including flags such as --help, --env and --root.
struct Exec: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec", abstract: "Run another nonterminal process in a container.",
        discussion: "Inherits process settings from the source bundle. Options must precede the container ID. "
            + "Terminal and descriptor handoff options are not implemented."
    )
    @ParentCommand var parent: RuntimeCommand
    @Option(name: .customLong("root"), help: "Directory holding container state.") var stateRoot: String?
    @Option(name: [.customShort("e"), .long], help: "Add or replace an environment entry NAME=value.") var env: [String] = []
    @Option(help: "Working directory inside the container.") var cwd: String?
    @Option(name: [.customShort("u"), .long], help: "Numeric uid[:gid] for the exec process.") var user: String?
    @Option(name: [.customShort("g"), .customLong("additional-gids")], help: "Append a numeric supplementary group ID (repeatable).")
    var additionalGids: [UInt32] = []
    // A bare flag sets no_new_privs, as in runc; absent keeps the process
    // setting. runc's explicit --no-new-privs=false has no equivalent here.
    @Flag(name: .customLong("no-new-privs"), help: "Set no_new_privs for the exec process.") var noNewPrivs = false
    @Option(name: [.customShort("c"), .customLong("cap")], help: "Add a capability, such as CAP_CHOWN, to the exec process (repeatable).")
    var cap: [String] = []
    @Option(name: .customLong("pid-file"), help: "Write the host exec PID atomically to this path.") var pidFile: String?
    @Option(name: [.customShort("p"), .customLong("process")], help: "OCI process JSON file; overrides the bundle and process CLI settings.") var processFile: String?
    @Flag(name: [.customShort("d"), .long], help: "Return once exec succeeds.") var detach = false
    @Flag(name: .customLong("ignore-paused"), help: "Wait for a paused container to resume instead of failing.")
    var ignorePaused = false
    @Argument(parsing: .captureForPassthrough, help: "Container ID, executable (a name found through the process PATH, or a path), and its arguments.") var operands: [String] = []
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
        if processFile == nil {
            guard let executable = arguments.first, !executable.isEmpty else {
                throw ValidationError("exec requires an executable after the container ID")
            }
        }
        guard processFile != "" else { throw ValidationError("--process must not be empty") }
        guard (arguments + env + cap + [cwd, user, pidFile, processFile].compactMap { $0 }).allSatisfy({ !$0.utf8.contains(0) }) else {
            throw ValidationError("exec options and arguments must not contain NUL")
        }
    }

    mutating func run() throws {
        let status: Int32
        do {
            status = try globals.lifecycle().exec(
                id: ContainerID(id), arguments: arguments, environment: env, cwd: cwd, user: user,
                additionalGids: additionalGids, noNewPrivileges: noNewPrivs ? true : nil,
                capabilities: cap, detach: detach, pidFile: pidFile, processFile: processFile,
                ignorePaused: ignorePaused)
        } catch { throw failure(error) }
        throw ExitCode(status)
    }
}
