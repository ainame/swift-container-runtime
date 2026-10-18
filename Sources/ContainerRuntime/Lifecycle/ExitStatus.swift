/// A command's shell-style exit status, like a shell's `$?`.
///
/// The value is the workload's exit code (0...255), or 128 plus the signal
/// number when a signal killed it. Detached commands report ``success`` once
/// started, without waiting for the workload to finish.
///
/// The launcher passes this shell-style number through its own exit code,
/// so the original termination cause is unavailable. As with a shell, an
/// explicit exit code of 137 is indistinguishable from termination by signal 9.
/// ``signal`` and ``description`` interpret the number by convention only.
public struct ExitStatus: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The shell-style status in 0...255, suitable for a CLI's exit code.
    public let shellStatus: Int32

    /// Wraps a shell-style status at a public API boundary.
    ///
    /// - Parameter shellStatus: A decoded shell-style status, not a raw wait status.
    /// - Precondition: `shellStatus` is in 0...255.
    init(shellStatus: Int32) {
        precondition((0...255).contains(shellStatus))
        self.shellStatus = shellStatus
    }

    /// Status zero, also returned when a detached command starts successfully.
    public static let success = ExitStatus(shellStatus: 0)

    /// Whether the shell-style status is zero.
    public var isSuccess: Bool { shellStatus == 0 }

    /// The signal number inferred by shell convention for statuses 129...192.
    ///
    /// This is `shellStatus - 128` in that range and nil otherwise. It is not
    /// proof of signal termination: a workload can explicitly exit with the
    /// same status, and the launcher preserves only the shell-style number.
    public var signal: Int32? {
        (129...192).contains(shellStatus) ? shellStatus - 128 : nil
    }

    /// A readable status, interpreting signals by shell convention only.
    ///
    /// For example, status 3 is "exit status 3" and status 137 is
    /// "killed by signal 9 (status 137)". The latter can also represent an
    /// explicit exit code of 137; it does not establish the termination cause.
    public var description: String {
        if let signal {
            return "killed by signal \(signal) (status \(shellStatus))"
        }
        return "exit status \(shellStatus)"
    }
}
