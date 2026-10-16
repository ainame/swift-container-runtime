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
        var argv = try CStringVector(arguments)
        var status: Int32 = 0
        var failure = scr_failure()
        let result = hostname.withCString { hostname in
            unsafe argv.withPointers { pointers in
                // The synchronous C call does not retain either pointer in the
                // parent. Forked children use their inherited address space.
                unsafe scr_namespace_run(hostname, pointers, &status, &failure)
            }
        }
        guard result == 0 else {
            // Both C helpers return NUL-terminated static strings.
            let stage = unsafe String(cString: scr_stage_name(failure.stage))
            let message = unsafe String(cString: scr_error_message(failure.error_number))
            throw RuntimeError("\(stage): \(message) (errno \(failure.error_number))")
        }
        return status
    }
}

/// Owns one initialized byte slab. Raw pointers exist only during the C call.
private struct CStringVector: ~Copyable {
    private var storage: [CChar]
    private let offsets: [Int]

    init(_ strings: [String]) throws {
        var capacity = 0
        for string in strings {
            let (withTerminator, terminatorOverflow) = string.utf8.count.addingReportingOverflow(1)
            let (total, totalOverflow) = capacity.addingReportingOverflow(withTerminator)
            guard !terminatorOverflow, !totalOverflow else {
                throw RuntimeError("command arguments exceed addressable storage")
            }
            capacity = total
        }
        var starts: [Int] = []
        starts.reserveCapacity(strings.count)
        // Swift 6.4's OutputSpan tracks initialization; Array owns destruction.
        storage = Array(capacity: capacity) { output in
            for string in strings {
                starts.append(output.count)
                for byte in string.utf8CString { output.append(byte) }
            }
        }
        offsets = starts
    }

    @unsafe
    mutating func withPointers(
        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    ) -> Int32 {
        let starts = offsets
        return storage.withUnsafeMutableBufferPointer { bytes in
            // The byte slab cannot resize while borrowed here. All offsets
            // point to initialized, NUL-terminated strings in that slab.
            unsafe withTemporaryAllocation(of: UnsafeMutablePointer<CChar>?.self, capacity: starts.count + 1) { output in
                for offset in starts {
                    unsafe output.append(bytes.baseAddress!.advanced(by: offset))
                }
                unsafe output.append(nil)
                // Span borrows the initialized pointer vector. Neither the
                // vector nor its pointees may escape this nested callback.
                return unsafe output.span.withUnsafeBufferPointer { pointers in
                    unsafe body(pointers.baseAddress!)
                }
            }
        }
    }
}

public enum RuntimeDiagnostics {
    public static func writeError(_ message: String) {
        // C consumes the temporary NUL-terminated string synchronously.
        message.withCString { unsafe scr_write_error($0) }
    }
}
