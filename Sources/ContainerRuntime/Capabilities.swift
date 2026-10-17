/// A set of Linux capabilities as the kernel's bit mask: bit n is capability n.
public struct CapabilitySet: Sendable, Hashable, CustomStringConvertible {
    public let mask: UInt64

    public init(mask: UInt64) { self.mask = mask }

    /// OCI names indexed by capability number, through Linux 5.9's
    /// CAP_CHECKPOINT_RESTORE. Spelling is exact, as in runc.
    public static let knownNames: [String] = [
        "CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_DAC_READ_SEARCH", "CAP_FOWNER", "CAP_FSETID", "CAP_KILL",
        "CAP_SETGID", "CAP_SETUID", "CAP_SETPCAP", "CAP_LINUX_IMMUTABLE", "CAP_NET_BIND_SERVICE",
        "CAP_NET_BROADCAST", "CAP_NET_ADMIN", "CAP_NET_RAW", "CAP_IPC_LOCK", "CAP_IPC_OWNER", "CAP_SYS_MODULE",
        "CAP_SYS_RAWIO", "CAP_SYS_CHROOT", "CAP_SYS_PTRACE", "CAP_SYS_PACCT", "CAP_SYS_ADMIN", "CAP_SYS_BOOT",
        "CAP_SYS_NICE", "CAP_SYS_RESOURCE", "CAP_SYS_TIME", "CAP_SYS_TTY_CONFIG", "CAP_MKNOD", "CAP_LEASE",
        "CAP_AUDIT_WRITE", "CAP_AUDIT_CONTROL", "CAP_SETFCAP", "CAP_MAC_OVERRIDE", "CAP_MAC_ADMIN", "CAP_SYSLOG",
        "CAP_WAKE_ALARM", "CAP_BLOCK_SUSPEND", "CAP_AUDIT_READ", "CAP_PERFMON", "CAP_BPF", "CAP_CHECKPOINT_RESTORE",
    ]

    /// The capability number for an exact OCI name.
    public static func number(named name: String) -> Int? {
        knownNames.firstIndex(of: name)
    }

    public static func name(of number: Int) -> String {
        knownNames.indices.contains(number) ? knownNames[number] : "capability \(number)"
    }

    public func contains(_ number: Int) -> Bool {
        (0..<64).contains(number) && mask & (1 << UInt64(number)) != 0
    }

    public func subtracting(_ other: CapabilitySet) -> CapabilitySet { CapabilitySet(mask: mask & ~other.mask) }
    public func intersection(_ other: CapabilitySet) -> CapabilitySet { CapabilitySet(mask: mask & other.mask) }
    public var isEmpty: Bool { mask == 0 }

    /// Member numbers in ascending order.
    public var numbers: [Int] { (0..<64).filter { contains($0) } }
    public var names: [String] { numbers.map(Self.name(of:)) }
    public var description: String { isEmpty ? "none" : names.joined(separator: ", ") }
}

/// `process.capabilities`: all five sets, each replacing the caller's.
///
/// The plan keeps this nil when the object is absent, in which case runc
/// (and this runtime) leaves the inherited sets alone: a root workload keeps
/// the runtime's capabilities, and a non-root uid loses its permitted,
/// effective, and ambient sets through setuid (bounding and inheritable
/// stay the caller's). A present object is authoritative, and an absent member means an
/// empty set, so `{}` drops every capability, including the bounding set.
public struct ProcessCapabilities: Sendable, Equatable {
    public let bounding: CapabilitySet
    public let effective: CapabilitySet
    public let inheritable: CapabilitySet
    public let permitted: CapabilitySet
    public let ambient: CapabilitySet

    /// Every set member, for the kernel range check.
    var requested: CapabilitySet {
        CapabilitySet(mask: bounding.mask | effective.mask | inheritable.mask | permitted.mask | ambient.mask)
    }

    /// Parses names and checks the relations Linux enforces when the sets are
    /// installed. runc warns about and ignores unknown names and ambient
    /// capabilities the kernel refuses; this runtime rejects both, so a
    /// configuration never runs with fewer (or other) capabilities than it says.
    init(_ configuration: OCIConfiguration.Capabilities) throws {
        func parse(_ names: [String]?, _ member: String) throws -> CapabilitySet {
            var mask: UInt64 = 0
            for (index, name) in (names ?? []).enumerated() {
                guard let number = CapabilitySet.number(named: name) else {
                    // Suggest the spelling runc would have accepted, if any.
                    let upper = name.uppercased()
                    let suggestion = [upper, "CAP_" + upper].first { CapabilitySet.number(named: $0) != nil }
                    let hint = suggestion.map { "did you mean \($0)?" } ?? "such as CAP_CHOWN"
                    throw RuntimeError(
                        "config.json: process.capabilities.\(member)[\(index)]: unknown capability \"\(name)\"; names are exact, \(hint)"
                    )
                }
                // Duplicates are harmless, as in runc.
                mask |= 1 << UInt64(number)
            }
            return CapabilitySet(mask: mask)
        }
        bounding = try parse(configuration.bounding, "bounding")
        effective = try parse(configuration.effective, "effective")
        inheritable = try parse(configuration.inheritable, "inheritable")
        permitted = try parse(configuration.permitted, "permitted")
        ambient = try parse(configuration.ambient, "ambient")

        // capset(2) refuses an effective capability that is not permitted.
        let notPermitted = effective.subtracting(permitted)
        guard notPermitted.isEmpty else {
            throw RuntimeError(
                "config.json: process.capabilities.effective must be a subset of permitted; add to permitted or remove from effective: \(notPermitted)"
            )
        }
        // Inheritable is not checked against bounding: capset(2) keeps a bit
        // the init already inherited even outside the reduced bounding set,
        // so only the kernel, which knows the inherited sets, can decide.
        // PR_CAP_AMBIENT_RAISE needs the capability permitted and inheritable.
        let ambientNotPermitted = ambient.subtracting(permitted)
        let ambientNotInheritable = ambient.subtracting(inheritable)
        guard ambientNotPermitted.isEmpty, ambientNotInheritable.isEmpty else {
            var missing: [String] = []
            if !ambientNotPermitted.isEmpty { missing.append("not permitted: \(ambientNotPermitted)") }
            if !ambientNotInheritable.isEmpty { missing.append("not inheritable: \(ambientNotInheritable)") }
            throw RuntimeError(
                "config.json: process.capabilities.ambient must be a subset of both permitted and inheritable; \(missing.joined(separator: "; "))"
            )
        }
    }

    /// Rejects capabilities above the running kernel's `cap_last_cap`. runc
    /// ignores them with a warning; a request the kernel cannot honor is an
    /// error here.
    func checkSupported(lastCapability: Int) throws {
        let unsupported = requested.numbers.filter { $0 > lastCapability }
        guard unsupported.isEmpty else {
            let names = unsupported.map { "\(CapabilitySet.name(of: $0)) (\($0))" }.joined(separator: ", ")
            throw RuntimeError(
                "config.json: process.capabilities: \(names) not supported by this kernel (cap_last_cap is \(lastCapability))"
            )
        }
    }

    /// Parses `/proc/sys/kernel/cap_last_cap`. The capset(2) ABI used here
    /// carries 64 capabilities.
    static func parseLastCapability(_ bytes: [UInt8]) throws -> Int {
        let text = String(decoding: bytes, as: UTF8.self)
        let trimmed = text.hasSuffix("\n") ? String(text.dropLast()) : text
        guard !trimmed.isEmpty, trimmed.utf8.count <= 3, trimmed.allSatisfy({ ("0"..."9").contains($0) }),
              let value = Int(trimmed) else {
            throw RuntimeError("cannot parse /proc/sys/kernel/cap_last_cap: \(trimmed)")
        }
        guard value < 64 else {
            throw RuntimeError("kernel cap_last_cap \(value) exceeds the 64 capabilities this runtime can set")
        }
        return value
    }
}
