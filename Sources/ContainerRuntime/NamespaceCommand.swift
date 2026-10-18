#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import LinuxAPI
#endif

public struct RuntimeError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

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
    static func launch(
        hostname: UnsafePointer<CChar>,
        arguments: UnsafePointer<UnsafeMutablePointer<CChar>?>
    ) throws -> Int32 {
        let hostnameLength = unsafe strlen(hostname)
        return unsafe try NamespaceLauncher.run(namespaceFlags: Int32(CLONE_NEWUTS | CLONE_NEWPID | CLONE_NEWNS)) { report, _, _ in
            guard unsafe mount("proc", "/proc", "proc", UInt(MS_NOSUID | MS_NODEV | MS_NOEXEC), nil) == 0 else {
                return LaunchRecord.reportFailure(to: report, at: .procMount)
            }
            guard unsafe sethostname(hostname, hostnameLength) == 0 else { return LaunchRecord.reportFailure(to: report, at: .hostname) }
            _ = unsafe execv(arguments[0]!, arguments)
            return LaunchRecord.reportFailure(to: report, at: .execute)
        }
    }
}
#endif
