#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SystemPackage

/// The OCI state a hook reads on its stdin.
struct HookState: Encodable, Sendable {
    enum Status: String, Encodable, Sendable {
        case creating, created, running, stopped
    }

    let ociVersion: String
    let id: String
    let status: Status
    /// The init's PID as the hook's caller sees it; omitted once stopped.
    let pid: Int32?
    let bundle: String
    let annotations: [String: String]?

    init(ociVersion: String, id: String, status: Status, pid: Int32?, bundle: String, annotations: [String: String]) {
        self.ociVersion = ociVersion
        self.id = id
        self.status = status
        self.pid = pid
        self.bundle = bundle
        self.annotations = annotations.isEmpty ? nil : annotations
    }

    init(record: ContainerRecord, status: Status, pid: Int32?) {
        ociVersion = record.ociVersion
        id = record.id
        self.status = status
        self.pid = pid
        bundle = record.bundle
        annotations = record.annotations.isEmpty ? nil : record.annotations
    }

    func encoded() throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Array(try encoder.encode(self))
    }
}

extension ContainerHooks {
    /// Runs the hooks of `phases` in order in the runtime namespace, each with
    /// `state` on stdin. The first failing hook throws, with its output.
    func run(_ phases: [Phase], state: HookState) throws {
        let json = try state.encoded()
        for phase in phases {
            for (index, hook) in self[phase].enumerated() {
                var strings = try CStringVector(groups: [[hook.path], hook.argv] + (hook.env.map { [$0] } ?? []))
                let starts = strings.groupStarts
                var output: [UInt8] = []
                let outcome = unsafe strings.withPointers { pointers in
                    let prepared = unsafe PreparedHook(
                        path: (pointers + starts[0])[0]!, arguments: pointers + starts[1],
                        environment: hook.env == nil ? nil : pointers + starts[2], timeout: hook.duration)
                    return unsafe HookRunner.run(
                        prepared, writeState: { _ = Self.sendAll(json.span.bytes, to: $0) },
                        consume: { chunk in
                            guard output.count < Self.outputLimit else { return }
                            chunk.withUnsafeBytes { unsafe output.append(contentsOf: $0.prefix(Self.outputLimit - output.count)) }
                        })
                }
                guard outcome == .success else {
                    throw RuntimeError(Self.failureMessage(phase, index, outcome, output: output))
                }
            }
        }
    }

    /// runc's message shape: `error running <phase> hook #<n>: <reason>`,
    /// with the hook's combined output when it wrote any.
    static func failureMessage(_ phase: Phase, _ index: Int, _ outcome: HookOutcome, output: [UInt8] = []) -> String {
        let isSpace = { (byte: UInt8) in byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r") }
        let trimmed = output.drop(while: isSpace).reversed().drop(while: isSpace).reversed()
        let text = String(decoding: Array(trimmed), as: UTF8.self)
        return "error running \(phase.rawValue) hook #\(index): \(outcome.reason)" + (text.isEmpty ? "" : ", output: \(text)")
    }

    /// Output kept for an error message.
    private static let outputLimit = 64 * 1024

    /// Writes all of `bytes`, false once the hook stopped reading; a hook
    /// that never reads its state only loses the rest. Allocates nothing.
    @discardableResult
    static func sendAll(_ bytes: RawSpan, to socket: FileDescriptor) -> Bool {
        var sent = 0
        while sent < bytes.byteCount {
            guard let count = try? Kernel.Socket.send(socket, bytes.extracting(sent...)), count > 0 else { return false }
            sent += count
        }
        return true
    }
}
