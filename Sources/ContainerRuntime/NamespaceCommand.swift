public struct RuntimeError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Linux limits UTS hostnames to 64 bytes.
func validateHostname(_ hostname: String) throws {
    guard !hostname.isEmpty, hostname.utf8.count <= 64, !hostname.utf8.contains(0) else {
        throw RuntimeError("hostname must contain 1...64 UTF-8 bytes and no NUL")
    }
}

/// A namespace experiment. This does not isolate the root filesystem or privileges.
public struct NamespaceCommand: Sendable {
    public let hostname: String
    public let arguments: [String]

    public init(hostname: String, arguments: [String]) throws {
        try validateHostname(hostname)
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
