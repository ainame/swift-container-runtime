import ArgumentParser
import Foundation
import Testing
@testable import RuntimeCLI

@Test(arguments: [
    ["--root", "/tmp/state", "--log", "/tmp/log.json", "--log-format", "json", "--debug", "create", "--bundle", "/tmp/bundle", "--pid-file", "/tmp/init.pid", "box"],
    ["create", "--log", "/tmp/log.json", "--log-format", "json", "--debug", "box"],
    ["--log", "/tmp/log.json", "--log-format", "json", "--debug", "exec", "--process", "/tmp/process.json", "--detach", "--pid-file", "/tmp/exec.pid", "box"],
    ["exec", "--log", "/tmp/log.json", "--log-format", "json", "--debug", "box", "echo", "--log", "workload"],
    ["ps", "--log", "/tmp/log.json", "--log-format", "json", "--debug", "box", "--log", "ps-argument"],
])
func parsesEngineLoggingOptions(_ arguments: [String]) throws {
    let command = try #require(RuntimeCommand.parseAsRoot(arguments) as? any RuntimeLoggingCommand)
    #expect(command.globals.log == "/tmp/log.json")
    #expect(command.globals.logFormat == .json)
    #expect(command.globals.debug)
}

@Test(arguments: [["--log", "", "start", "box"], ["--log", "a\0b", "start", "box"],
                  ["--log-format", "xml", "start", "box"], ["exec", "--log", "", "box", "true"]])
func rejectsInvalidLoggingOptions(_ arguments: [String]) {
    #expect(throws: (any Error).self) { try RuntimeCommand.parseAsRoot(arguments) }
}

@Test func appendsConsumerCompatibleJSONRecords() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: path) }
    var options = try GlobalOptions.parse([])
    options.log = path.path
    options.logFormat = .json
    let message = "failed \"exec\"\nwith a new line and \\ slash 日本語"
    do {
        let log = try RuntimeLog(options: options)
        log.write(level: "error", message: "earlier failure")
    }
    do {
        let log = try RuntimeLog(options: options)
        log.write(level: "debug", message: "running exec")
        log.write(level: "error", message: message)
    }
    // Match the shim consumer: decode every record, parse its timestamp, take
    // the last level=error message. Embedded newlines must stay in one record.
    struct Record: Decodable { let level: String; let msg: String; let time: String }
    let records = try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map {
        try JSONDecoder().decode(Record.self, from: Data($0.utf8))
    }
    #expect(records.count == 3)
    #expect(records.last(where: { $0.level == "error" })?.msg == message)
    for record in records { #expect((try? Date(record.time, strategy: .iso8601)) != nil) }
}

@Test func logOpenFailureIsARuntimeFailure() throws {
    var options = try GlobalOptions.parse([])
    options.log = "/no-such-sct-directory/\(UUID().uuidString)/log"
    #expect(throws: CommandFailure.self) { _ = try RuntimeLog(options: options) }
}

@Test(arguments: ["create", "start", "exec", "exec-2", "delete", "delete-2", "kill"])
func replaysCapturedContainerdArguments(_ name: String) throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/engine-baseline/\(name).argv.json")
    let arguments = try JSONDecoder().decode([String].self, from: Data(contentsOf: fixture))
    let command = try #require(RuntimeCommand.parseAsRoot(arguments) as? any RuntimeLoggingCommand)
    #expect(command.globals.logFormat == .json)
    #expect(command.globals.root == "/run/containerd/runc/default")
}
