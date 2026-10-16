import CRuntime

public struct RuntimeError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// A namespace experiment. This does not isolate the root filesystem or privileges.
public struct NamespaceCommand: Sendable {
    public let hostname: String
    public let arguments: [String]

    public init(hostname: String, arguments: [String]) throws {
        guard !hostname.isEmpty, hostname.utf8.count <= 64, !hostname.utf8.contains(0) else {
            throw RuntimeError("hostname must contain 1...64 UTF-8 bytes and no NUL")
        }
        guard let executable = arguments.first, executable.hasPrefix("/") else {
            throw RuntimeError("an absolute executable path is required after --")
        }
        guard arguments.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw RuntimeError("command arguments must not contain NUL")
        }
        self.hostname = hostname
        self.arguments = arguments
    }

    /// Synchronous by design: do not run namespace setup on an async executor.
    public func run() throws -> Int32 {
        let argv = CStringVector(arguments)
        var status: Int32 = 0
        var failure = scr_failure()
        let result = hostname.withCString { hostname in
            argv.withPointers { pointers in
                scr_namespace_run(hostname, pointers, &status, &failure)
            }
        }
        guard result == 0 else {
            let stage = String(cString: scr_stage_name(failure.stage))
            let message = String(cString: scr_error_message(failure.error_number))
            throw RuntimeError("\(stage): \(message) (errno \(failure.error_number))")
        }
        return status
    }
}

/// Owns stable NUL-terminated storage across the C launch call and its forks.
private struct CStringVector: ~Copyable {
    private let pointers: [UnsafeMutablePointer<CChar>?]

    init(_ strings: [String]) {
        pointers = strings.map { string in
            let bytes = string.utf8CString
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            bytes.withUnsafeBufferPointer { buffer in
                pointer.initialize(from: buffer.baseAddress!, count: buffer.count)
            }
            return pointer
        } + [nil]
    }

    borrowing func withPointers<Result>(
        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    deinit {
        for pointer in pointers { pointer?.deallocate() }
    }
}

public enum RuntimeDiagnostics {
    public static func writeError(_ message: String) {
        message.withCString { scr_write_error($0) }
    }
    public static func exit(_ status: Int32) -> Never {
        scr_exit(status)
        fatalError("exit returned")
    }
}
