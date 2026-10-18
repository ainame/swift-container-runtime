import ArgumentParser
import ContainerRuntime

/// Shared options; passthrough commands inherit these from their parent.
struct GlobalOptions: ParsableArguments {
    @Option(help: ArgumentHelp("Directory holding container state.", valueName: "path"))
    var root = ContainerLifecycle.defaultRoot

    @Option(help: "Append runtime diagnostics to this file.")
    var log: String?

    @Option(name: .customLong("log-format"), help: "Diagnostic format: text or json.")
    var logFormat: LogFormat = .text

    @Flag(help: "Enable debug diagnostics.")
    var debug = false

    func validate() throws {
        guard !root.isEmpty, !root.utf8.contains(0) else {
            throw ValidationError("--root must be non-empty and contain no NUL")
        }
        if let log, log.isEmpty || log.utf8.contains(0) {
            throw ValidationError("--log must be non-empty and contain no NUL")
        }
    }

    func lifecycle() throws -> ContainerLifecycle {
        try ContainerLifecycle(root: root)
    }
}

enum LogFormat: String, ExpressibleByArgument {
    case text, json
}

/// Separate storage avoids ArgumentParser reusing the parent's decoded defaults
/// in commands that stop parsing at their first positional argument.
struct PassthroughLoggingOptions: ParsableArguments {
    @Option(help: "Append runtime diagnostics to this file.") var log: String?
    @Option(name: .customLong("log-format"), help: "Diagnostic format: text or json.") var logFormat: LogFormat?
    @Flag(help: "Enable debug diagnostics.") var debug = false

    func applying(to parent: GlobalOptions) -> GlobalOptions {
        var result = parent
        if let log { result.log = log }
        if let logFormat { result.logFormat = logFormat }
        result.debug = result.debug || debug
        return result
    }
}
