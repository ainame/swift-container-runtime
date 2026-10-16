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

    /// Namespace setup runs before background work begins. The Linux
    /// launch rejects multithreaded callers before executing Swift in a child.
    @available(*, noasync, message: "launch namespaces before starting async work")
    public func run() throws -> Int32 {
        #if os(Linux)
        var argv = try CStringVector(arguments)
        return try hostname.withCString { hostname in
            unsafe try argv.withPointers { pointers in
                unsafe try runNamespaceProcess(hostname: hostname, arguments: pointers)
            }
        }
        #else
        throw RuntimeError("namespace launch requires Linux")
        #endif
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
        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) throws -> Int32
    ) rethrows -> Int32 {
        let starts = offsets
        return try storage.withUnsafeMutableBufferPointer { bytes in
            // The byte slab cannot resize while borrowed here. All offsets
            // point to initialized, NUL-terminated strings in that slab.
            unsafe try withTemporaryAllocation(of: UnsafeMutablePointer<CChar>?.self, capacity: starts.count + 1) { output in
                for offset in starts {
                    unsafe output.append(bytes.baseAddress!.advanced(by: offset))
                }
                unsafe output.append(nil)
                // Span borrows the initialized pointer vector. Neither the
                // vector nor its pointees may escape this nested callback.
                return unsafe try output.span.withUnsafeBufferPointer { pointers in
                    unsafe try body(pointers.baseAddress!)
                }
            }
        }
    }
}
