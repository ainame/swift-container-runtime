
/// Caller descriptors 3..<3+count that reach the workload at the same
/// numbers, as runc's `--preserve-fds`. The runtime never wraps, closes,
/// renumbers, or chowns them; their type and target are not checked.
public struct PreservedDescriptors: Sendable, Equatable {
    /// How many descriptors, from 3 up, the workload inherits.
    public let count: Int32

    /// The first descriptor the workload must not inherit.
    public var firstInternal: Int32 { 3 + count }

    /// `firstInternal` for `close_range`, which takes an unsigned start. The
    /// conversion cannot trap: `init` keeps it in 3...Int32.max.
    var closeRangeStart: UInt32 { UInt32(firstInternal) }

    /// No preserved descriptors beyond stdin, stdout and stderr.
    public static let none = PreservedDescriptors(validated: 0)

    private init(validated count: Int32) { self.count = count }

    /// Rejects negative counts (runc ignores them) and any count where
    /// 3+count leaves Int32. There is no lower arbitrary limit; `verify`
    /// bounds the real work by the first missing descriptor.
    public init(count: Int) throws {
        guard count >= 0 else { throw RuntimeError("--preserve-fds must not be negative: \(count)") }
        guard let narrow = Int32(exactly: count), !narrow.addingReportingOverflow(3).overflow else {
            throw RuntimeError("--preserve-fds \(count) exceeds the descriptor number range")
        }
        self.count = narrow
    }

    /// Checks that each preserved descriptor is open and not close-on-exec,
    /// stopping at the first failure. `flags` returns `F_GETFD` or nil.
    ///
    /// By contract, preserved descriptors must already be inheritable: only
    /// descriptors without FD_CLOEXEC survive the caller's own exec, and this
    /// runtime opens every descriptor of its own close-on-exec. A caller's
    /// legitimate close-on-exec descriptor is therefore rejected rather than
    /// cleared, so a runtime handle in the range can never be passed on. Run
    /// once before any runtime allocation could fill a hole, and again just
    /// before fork: then the range holds only inheritable descriptors, and
    /// every later runtime descriptor takes the lowest free number, at or
    /// above `firstInternal`. This is stricter than runc, which passes any
    /// open descriptor.
    public func verify(flags: (Int32) -> Int32? = PreservedDescriptors.descriptorFlags) throws {
        var offset: Int32 = 0
        while offset < count {
            let descriptor = 3 + offset
            guard let value = flags(descriptor) else {
                throw RuntimeError("unable to stat preserved-fd \(offset) (of \(count)): descriptor \(descriptor) is not open")
            }
            guard value & Kernel.File.closeOnExecFlag == 0 else {
                throw RuntimeError("preserved-fd \(offset) (of \(count)): descriptor \(descriptor) is close-on-exec; preserved descriptors must be inheritable")
            }
            offset += 1
        }
    }

    /// The descriptor flags of an open descriptor, from `fcntl(F_GETFD)`.
    ///
    /// - Returns: The `FD_*` flag bits (such as `FD_CLOEXEC`), or nil when
    ///   `descriptor` is not open.
    public static func descriptorFlags(_ descriptor: Int32) -> Int32? {
        Kernel.File.descriptorFlags(descriptor)
    }
}
