/// Normalized cgroup-v2 device policy, following runc's cgroup-v1-compatible
/// rule updates. Wildcard resets clear exceptions; partial wildcard holes fail.
struct DevicePolicy: Sendable, Equatable {
    /// A device selector; a nil major or minor matches any number.
    struct Device: Hashable, Sendable {
        /// BPF_DEVCG_DEV_BLOCK (1) or BPF_DEVCG_DEV_CHAR (2).
        let type: UInt32
        let major: UInt32?
        let minor: UInt32?
    }
    /// Accesses to a device that differ from the default verdict.
    struct Exception: Sendable, Equatable {
        let device: Device
        /// BPF_DEVCG_ACC_MKNOD (1), READ (2) and WRITE (4) bits.
        let access: UInt32
    }
    /// The verdict for a device no exception matches.
    let defaultAllow: Bool
    /// Exceptions in a deterministic order, so equal policies compile to the
    /// same program.
    let exceptions: [Exception]

    /// Applies `linux.resources.devices` in order, followed by runc's default
    /// allowed devices, as cgroup v1 would.
    /// - Throws: `RuntimeError` for an invalid rule or an ambiguous partial
    ///   removal from a wildcard exception.
    init(_ input: [OCIConfiguration.DeviceRule]) throws {
        var defaultAllow = false
        var entries: [Device: UInt32] = [:]
        // runc specconv appends default devices after the caller's rules. The
        // wildcard mknod allows are needed while init populates its /dev tmpfs.
        let rules = input + Self.standardRules
        guard rules.count <= 512 else { throw RuntimeError("device policy exceeds 512 rules") }
        for (index, rule) in rules.enumerated() {
            let field = "linux.resources.devices[\(index)]"
            guard !rule.access.isEmpty, rule.access.allSatisfy({ "rwm".contains($0) }) else {
                throw RuntimeError("\(field).access must be a non-empty combination of r, w, m")
            }
            let access = rule.access.reduce(UInt32(0)) { $0 | ($1 == "m" ? 1 : $1 == "r" ? 2 : 4) }
            let type = rule.type ?? "a"
            guard ["", "a", "b", "c"].contains(type) else { throw RuntimeError("\(field).type must be a, b or c") }
            func number(_ value: Int64?, _ name: String) throws -> UInt32? {
                guard let value, value != -1 else { return nil }
                guard let result = UInt32(exactly: value) else { throw RuntimeError("\(field).\(name) must be -1 or a UInt32 device number") }
                return result
            }
            let device = Device(type: type == "b" ? 1 : 2, major: try number(rule.major, "major"), minor: try number(rule.minor, "minor"))
            if type == "a" || type.isEmpty {
                // The cgroup wildcard resets the whole policy, irrespective of
                // its numeric selectors or the supplied nonempty access mask.
                defaultAllow = rule.allow
                entries.removeAll()
            } else if rule.allow != defaultAllow {
                entries[device, default: 0] |= access
            } else {
                // Removing one exact exception cannot carve a hole out of an
                // existing broader wildcard. runc rejects that ambiguity too.
                for wildcard in [Device(type: device.type, major: nil, minor: device.minor),
                                 Device(type: device.type, major: device.major, minor: nil),
                                 Device(type: device.type, major: nil, minor: nil)] where wildcard != device {
                    if (entries[wildcard] ?? 0) & access != 0 {
                        throw RuntimeError("\(field): cannot punch a hole in an existing wildcard device rule")
                    }
                }
                let remaining = (entries[device] ?? 0) & ~access
                entries[device] = remaining == 0 ? nil : remaining
            }
        }
        self.defaultAllow = defaultAllow
        self.exceptions = entries.map { Exception(device: $0.key, access: $0.value) }.sorted {
            let a = $0.device, b = $1.device
            if a.type != b.type { return a.type < b.type }
            if a.major != b.major { return (a.major.map(Int64.init) ?? -1) < (b.major.map(Int64.init) ?? -1) }
            return (a.minor.map(Int64.init) ?? -1) < (b.minor.map(Int64.init) ?? -1)
        }
    }

    /// runc's AllowedDevices: mknod of any device, plus /dev/null, zero, full,
    /// tty, random, urandom, console, ptmx and every /dev/pts device.
    private static var standardRules: [OCIConfiguration.DeviceRule] {
        var rules = ["b", "c"].map { OCIConfiguration.DeviceRule(allow: true, type: $0, access: "m") }
        for (major, minor) in [(1, 3), (1, 5), (1, 7), (1, 8), (1, 9), (5, 0), (5, 1), (5, 2)] {
            rules.append(OCIConfiguration.DeviceRule(allow: true, type: "c", major: Int64(major), minor: Int64(minor), access: "rwm"))
        }
        rules.append(OCIConfiguration.DeviceRule(allow: true, type: "c", major: 136, access: "rwm"))
        return rules
    }
}
