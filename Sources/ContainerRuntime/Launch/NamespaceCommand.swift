import SystemPackage

/// A namespace experiment. This does not isolate the root filesystem or privileges.
public struct NamespaceCommand: Sendable {
    public let hostname: String
    public let arguments: [String]

    public init(hostname: String, arguments: [String]) throws {
        try NamespaceCommand.validateHostname(hostname)
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
                unsafe try Self.launch(hostname: hostname, arguments: pointers)
            }
        }
        #else
        throw RuntimeError("namespace launch requires Linux")
        #endif
    }
}

extension NamespaceCommand {
    /// Linux limits UTS hostnames to 64 bytes.
    static func validateHostname(_ hostname: String) throws {
        guard !hostname.isEmpty, hostname.utf8.count <= 64, !hostname.utf8.contains(0) else {
            throw RuntimeError("hostname must contain 1...64 UTF-8 bytes and no NUL")
        }
    }
}

#if os(Linux)
extension NamespaceCommand {
    /// All borrowed buffers remain alive until both launch branches finish. This
    /// entry point is private to the synchronous, single-thread-checked Swift path.
    @unsafe
    private static func launch(
        hostname: UnsafePointer<CChar>,
        arguments: UnsafePointer<UnsafeMutablePointer<CChar>?>
    ) throws -> Int32 {
        unsafe try NamespaceLauncher.run(unsharing: [.uts, .pid, .mount]) { report, _, _ in
            if let error = Errno.failure({ () throws(Errno) in
                try unsafe Kernel.Mount.mount(source: "proc", target: "/proc", type: "proc", flags: [.noSetUserID, .noDevices, .noExecute])
            }) {
                return LaunchRecord.reportFailure(to: report, at: .procMount, error: error)
            }
            if let error = Errno.failure({ () throws(Errno) in try unsafe Kernel.Process.setHostname(hostname) }) {
                return LaunchRecord.reportFailure(to: report, at: .hostname, error: error)
            }
            let error = unsafe Kernel.Process.execute(arguments[0]!, arguments: arguments)
            return LaunchRecord.reportFailure(to: report, at: .execute, error: error)
        }
    }
}
#endif
