import SystemPackage

/// A namespace experiment. This does not isolate the root filesystem or privileges.
public struct NamespaceCommand: Sendable {
    /// The hostname set in the new UTS namespace.
    public let hostname: String
    /// The absolute executable path followed by its arguments.
    public let arguments: [String]

    /// - Throws: `RuntimeError` for a hostname outside 1...64 bytes, a
    ///   relative executable, or an argument containing NUL.
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

    /// Runs `arguments` in new UTS, PID and mount namespaces with a fresh
    /// `/proc` and `hostname`, and waits for it. Call this before starting
    /// background work: the launch rejects multithreaded callers.
    ///
    /// - Returns: The command's shell-style ``ExitStatus``: its exit code
    ///   (0...255), or 128 plus the signal number when a signal killed it.
    ///   Signal interpretation is conventional: an explicit exit code can
    ///   have the same value.
    /// - Throws: `RuntimeError` when the namespaces cannot be set up.
    @available(*, noasync, message: "launch namespaces before starting async work")
    public func run() throws -> ExitStatus {
        var argv = try CStringVector(arguments)
        let status = try hostname.withCString { hostname in
            unsafe try argv.withPointers { pointers in
                unsafe try Self.launch(hostname: hostname, arguments: pointers)
            }
        }
        return ExitStatus(shellStatus: status)
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
