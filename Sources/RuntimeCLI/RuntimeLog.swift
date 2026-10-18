import ArgumentParser
import ContainerRuntime
import Foundation
import SystemPackage

/// One synchronous command owns its log. No global state or threads are needed
/// before fork, and close-on-exec prevents the workload inheriting the log file.
struct RuntimeLog: ~Copyable {
    private let file: FileDescriptor?
    private let format: LogFormat

    init(options: GlobalOptions) throws {
        format = options.logFormat
        if let path = options.log {
            do {
                file = try FileDescriptor.open(
                    FilePath(path), .writeOnly, options: [.create, .append, .closeOnExec],
                    permissions: [.ownerRead, .ownerWrite, .groupRead, .otherRead])
            } catch {
                throw CommandFailure(message: "cannot open log file \(path): \(error)", status: 1)
            }
        } else {
            file = nil
        }
    }

    deinit { try? file?.close() }

    func write(level: String, message: String) {
        do {
            let time = Date().ISO8601Format()
            let line: String
            switch format {
            case .json:
                let data = try JSONEncoder().encode(Record(level: level, msg: message, time: time))
                line = String(decoding: data, as: UTF8.self)
            case .text:
                // JSON string escaping also keeps text records on one line.
                let escaped = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
                line = "time=\"\(time)\" level=\(level) msg=\(escaped)"
            }
            _ = try (file ?? .standardError).writeAll((line + "\n").utf8)
        } catch {
            RuntimeDiagnostics.writeError("srunc: cannot write runtime log: \(error)")
        }
    }

    func failure(_ message: String) {
        if file == nil, format == .text {
            RuntimeDiagnostics.writeError("srunc: \(message)")
            return
        }
        write(level: "error", message: message)
        if file != nil {
            RuntimeDiagnostics.writeError("srunc: \(message)")
        }
    }

    private struct Record: Encodable {
        let level: String
        let msg: String
        let time: String
    }
}

protocol RuntimeLoggingCommand: ParsableCommand {
    var globals: GlobalOptions { get }
}

protocol RuntimeDescriptorCommand: RuntimeLoggingCommand {
    var descriptors: DescriptorOptions { get }
}

extension RuntimeDescriptorCommand {
    /// Check before opening the log can fill a missing caller descriptor.
    func callerDescriptorFailure() -> CommandFailure? {
        do {
            try PreservedDescriptors(count: descriptors.preserveFDs).verify()
            return nil
        } catch {
            return CommandFailure.report(error, status: self is Run ? 125 : 1)
        }
    }
}

extension RuntimeCommand {
    static func main() {
        // Parsing help/version must retain ArgumentParser's clean exit behavior.
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            var command = try parseAsRoot(arguments)
            let options = try (command as? any RuntimeLoggingCommand)?.globals ?? GlobalOptions.parse([])
            let descriptorFailure = (command as? any RuntimeDescriptorCommand)?.callerDescriptorFailure()
            let log = try RuntimeLog(options: options)
            if options.debug {
                // Do not log argv, environment or bundle contents: they can contain secrets.
                log.write(level: "debug", message: "running \(type(of: command).configuration.commandName ?? "command")")
            }
            do {
                if let descriptorFailure { throw descriptorFailure }
                try command.run()
            } catch let failure as CommandFailure {
                log.failure(failure.message)
                exit(withError: ExitCode(failure.status))
            } catch {
                // A nonzero workload exit is an outcome, not a runtime failure.
                if !(error is ExitCode), exitCode(for: error) != .success {
                    log.failure(message(for: error))
                }
                exit(withError: error)
            }
        } catch {
            // The engine passes globals before the command. Preserve diagnostics
            // for rejected command flags/fields even when command parsing fails.
            if !(error is CommandFailure), exitCode(for: error) != .success {
                logParseFailure(error, arguments: arguments)
            }
            if let failure = error as? CommandFailure {
                RuntimeDiagnostics.writeError("srunc: \(failure.message)")
                exit(withError: ExitCode(failure.status))
            }
            exit(withError: error)
        }
    }

    private static func logParseFailure(_ error: any Error, arguments: [String]) {
        // Consume only the global prefix, never an exec/ps workload's arguments.
        var prefix: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--debug" || argument.hasPrefix("--log=")
                || argument.hasPrefix("--log-format=") || argument.hasPrefix("--root=") {
                prefix.append(argument)
                index += 1
            } else if ["--log", "--log-format", "--root"].contains(argument), index + 1 < arguments.count {
                prefix.append(contentsOf: arguments[index...index + 1])
                index += 2
            } else {
                break
            }
        }
        guard let options = try? GlobalOptions.parse(prefix), options.log != nil else { return }
        do {
            let log = try RuntimeLog(options: options)
            log.write(level: "error", message: message(for: error))
        } catch {
            RuntimeDiagnostics.writeError("srunc: \(error)")
        }
    }
}
