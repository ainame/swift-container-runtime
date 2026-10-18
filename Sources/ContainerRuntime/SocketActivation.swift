#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#else
import Glibc
#endif

/// systemd socket activation for `run` and `create`, as runc's
/// `activation.Files`: when the caller's LISTEN_PID names this process and
/// LISTEN_FDS is positive, descriptors 3..<3+count reach the workload ahead
/// of any `--preserve-fds` range, and the workload gets LISTEN_FDS=count and
/// LISTEN_PID=1. Like runc, LISTEN_PID is 1 even without a PID namespace.
/// LISTEN_FDNAMES is not forwarded; a value in the configuration is kept.
/// Anything malformed, mismatched, or not positive is ignored. `exec` never
/// uses this.
public struct SocketActivation: Sendable, Equatable {
    public let count: Int

    public static let none = SocketActivation(validated: 0)

    private init(validated count: Int) { self.count = count }

    /// Parses the two values as Go's `strconv.Atoi` does (optional sign,
    /// decimal digits, no whitespace, within Int), which Swift's `Int(_:)`
    /// matches on 64-bit platforms.
    public init(listenPID: String?, listenFDs: String?, processID: pid_t) {
        guard let listenPID, let pid = Int(listenPID), pid == Int(processID),
              let listenFDs, let count = Int(listenFDs), count > 0
        else {
            self = .none
            return
        }
        self.count = count
    }

    /// Reads this process's activation variables, without changing them.
    /// Call it from the single-threaded CLI before any launch: `getenv` is
    /// not safe against concurrent environment changes, and the PID must be
    /// this runtime's, not a child's.
    public static func inherited() -> SocketActivation {
        func read(_ name: String) -> String? {
            guard let value = unsafe getenv(name) else { return nil }
            return unsafe String(validatingCString: value)
        }
        return SocketActivation(listenPID: read("LISTEN_PID"), listenFDs: read("LISTEN_FDS"), processID: getpid())
    }

    /// Variables set in the workload after its configured environment.
    public var environment: [String] {
        count > 0 ? ["LISTEN_FDS=\(count)", "LISTEN_PID=1"] : []
    }

    /// The activation range followed by `preserveDescriptors` more caller
    /// descriptors, checked as one range so no runtime descriptor can fill
    /// a hole in either part.
    public func preserving(_ preserveDescriptors: Int) throws -> PreservedDescriptors {
        // Reject a negative count on its own before it could cancel activation.
        _ = try PreservedDescriptors(count: preserveDescriptors)
        let (total, overflow) = count.addingReportingOverflow(preserveDescriptors)
        guard !overflow else {
            throw RuntimeError("LISTEN_FDS \(count) plus --preserve-fds \(preserveDescriptors) exceeds the descriptor number range")
        }
        return try PreservedDescriptors(count: total)
    }
}
