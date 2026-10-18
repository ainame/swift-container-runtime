/// One validated `process.rlimits` entry.
///
/// Values are the kernel's 64-bit `prlimit64` values, so nothing is narrowed
/// to a platform `rlim_t`; `UInt64.max` is `RLIM64_INFINITY` ("unlimited").
public struct ResourceLimit: Sendable, Equatable, CustomStringConvertible {
    /// The Linux rlimit names runc and kontainer-runtime accept.
    public enum Resource: String, Sendable, CaseIterable {
        case cpu = "RLIMIT_CPU", fsize = "RLIMIT_FSIZE", data = "RLIMIT_DATA", stack = "RLIMIT_STACK"
        case core = "RLIMIT_CORE", rss = "RLIMIT_RSS", nproc = "RLIMIT_NPROC", nofile = "RLIMIT_NOFILE"
        case memlock = "RLIMIT_MEMLOCK", addressSpace = "RLIMIT_AS", locks = "RLIMIT_LOCKS"
        case sigpending = "RLIMIT_SIGPENDING", msgqueue = "RLIMIT_MSGQUEUE", nice = "RLIMIT_NICE"
        case rtprio = "RLIMIT_RTPRIO", rttime = "RLIMIT_RTTIME"

        /// The kernel's resource number in the generic Linux ABI (x86_64 and
        /// arm64). LinuxAPI.h checks each against the libc headers at compile
        /// time, so an architecture with another numbering does not build.
        public var number: Int32 {
            switch self {
            case .cpu: 0
            case .fsize: 1
            case .data: 2
            case .stack: 3
            case .core: 4
            case .rss: 5
            case .nproc: 6
            case .nofile: 7
            case .memlock: 8
            case .addressSpace: 9
            case .locks: 10
            case .sigpending: 11
            case .msgqueue: 12
            case .nice: 13
            case .rtprio: 14
            case .rttime: 15
            }
        }
    }

    /// `RLIM64_INFINITY`, the OCI and kernel spelling of "unlimited".
    public static let infinity = UInt64.max

    /// The limited resource.
    public let resource: Resource
    /// The soft limit, which the kernel enforces; ``infinity`` is unlimited.
    public let soft: UInt64
    /// The hard limit, the ceiling for the soft limit; ``infinity`` is unlimited.
    public let hard: UInt64

    public init(resource: Resource, soft: UInt64, hard: UInt64) {
        self.resource = resource
        self.soft = soft
        self.hard = hard
    }

    public var description: String {
        "\(resource.rawValue) soft \(Self.describe(soft)) hard \(Self.describe(hard))"
    }

    static func describe(_ value: UInt64) -> String {
        value == infinity ? "unlimited" : String(value)
    }
}

extension OCIRunPlan {
    /// Validates `process.rlimits` and keeps every entry in input order. An
    /// absent or empty list leaves every inherited limit alone. runc converts
    /// the list one-to-one and calls prlimit once per entry in that order, so
    /// a repeated type is set more than once and each step must succeed on
    /// its own: an earlier entry the kernel refuses fails setup even when a
    /// later one of the same type would be grantable.
    static func resourceLimits(_ entries: [OCIConfiguration.Rlimit]) throws -> [ResourceLimit] {
        let supported = ResourceLimit.Resource.allCases.map(\.rawValue).joined(separator: ", ")
        return try entries.enumerated().map { (index, entry) -> ResourceLimit in
            let field = "process.rlimits[\(index)]"
            guard let resource = ResourceLimit.Resource(rawValue: entry.type) else {
                throw RuntimeError("config.json: \(field).type \(entry.type) is not a Linux rlimit; supported: \(supported)")
            }
            // The kernel would reject this with EINVAL; runc fails create at
            // that prlimit. Report it before any process exists.
            guard entry.soft <= entry.hard else {
                throw RuntimeError(
                    "config.json: \(field) \(entry.type) soft limit \(ResourceLimit.describe(entry.soft)) exceeds hard limit \(ResourceLimit.describe(entry.hard))"
                )
            }
            return ResourceLimit(resource: resource, soft: entry.soft, hard: entry.hard)
        }
    }
}
