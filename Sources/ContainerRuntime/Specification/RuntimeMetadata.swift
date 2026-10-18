#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Identity reported by `--version` and the bounds reported by `features`.
public enum RuntimeMetadata {
    public static let name = "swift-container-runtime"
    /// The project has no release tags yet, so builds identify as a development version.
    public static let version = "0.0.0-dev"
    /// SwiftPM offers no reproducible way to inject `git describe` without build plugins or
    /// subprocesses, so the commit stays unknown. Like runc, the line is omitted when it is.
    public static let commit: String? = nil
    /// The runtime-spec version this runtime targets and `spec` writes (runc vendors 1.3.0).
    public static let ociVersion = "1.3.0"
    /// The oldest runtime-spec version whose configurations are accepted, as runc reports.
    public static let ociVersionMin = "1.0.0"

    /// runc's layout: `<name> version <v>`, an optional `commit:` line, then `spec: <oci>`.
    public static var versionText: String {
        var lines = ["\(name) version \(version)"]
        if let commit { lines.append("commit: \(commit)") }
        lines.append("spec: \(ociVersion)")
        return lines.joined(separator: "\n")
    }
}

/// The OCI runtime-spec `features` document (features.md), describing only what this build
/// implements. Kernel-dependent availability (for example a cgroup v2 mount) is checked when a
/// container runs, not here, matching runc. Absent (nil) lists mean "unknown"; empty lists mean
/// "none supported". When a surface is implemented, flip its entry in `current` and add a test.
/// Nested types and properties mirror the OCI features document's JSON keys of the same names.
public struct RuntimeFeatures: Codable, Equatable, Sendable {
    public struct Linux: Codable, Equatable, Sendable {
        public struct Cgroup: Codable, Equatable, Sendable {
            public var v1: Bool?
            public var v2: Bool?
            public var systemd: Bool?
            public var systemdUser: Bool?
            public var rdma: Bool?
        }

        public struct Enabled: Codable, Equatable, Sendable {
            public var enabled: Bool?
        }

        public struct IntelRdt: Codable, Equatable, Sendable {
            public var enabled: Bool?
            public var schemata: Bool?
            public var monitoring: Bool?
        }

        public struct MountExtensions: Codable, Equatable, Sendable {
            public var idmap: Enabled?
        }

        public var namespaces: [String]?
        public var capabilities: [String]?
        public var cgroup: Cgroup?
        public var seccomp: Enabled?
        public var apparmor: Enabled?
        public var selinux: Enabled?
        public var intelRdt: IntelRdt?
        public var mountExtensions: MountExtensions?
        public var netDevices: Enabled?
    }

    public var ociVersionMin: String
    public var ociVersionMax: String
    public var hooks: [String]?
    public var mountOptions: [String]?
    public var linux: Linux?

    /// The report for this build. Non-Linux builds cannot run containers, so they report no
    /// mount options and omit the `linux` section rather than claim support.
    public static var current: RuntimeFeatures {
        report(linux: Kernel.isLinux)
    }

    static func report(linux: Bool) -> RuntimeFeatures {
        let disabled = Linux.Enabled(enabled: false)
        return RuntimeFeatures(
            ociVersionMin: RuntimeMetadata.ociVersionMin,
            ociVersionMax: RuntimeMetadata.ociVersion,
            // No hook stage runs yet.
            hooks: [],
            // Generic flags the mount planner maps to MS_* bits. Filesystem data options such as
            // mode= or size= are excluded, as the schema requires.
            mountOptions: linux ? ["nodev", "noexec", "nosuid", "strictatime", "ro", "rw", "dev", "exec", "suid", "bind", "rbind", "private", "rprivate"] : [],
            linux: linux
                ? Linux(
                    namespaces: OCIRunPlan.Namespace.allCases.map(\.rawValue),
                    capabilities: CapabilitySet.knownNames,
                    cgroup: Linux.Cgroup(v1: false, v2: true, systemd: false, systemdUser: false, rdma: false),
                    seccomp: Linux.Enabled(enabled: true),
                    // Implemented, as runc reports them; a requested module the
                    // host does not enable fails when the container starts.
                    apparmor: Linux.Enabled(enabled: true),
                    selinux: Linux.Enabled(enabled: true),
                    intelRdt: Linux.IntelRdt(enabled: false, schemata: false, monitoring: false),
                    mountExtensions: Linux.MountExtensions(idmap: disabled),
                    netDevices: disabled)
                : nil)
    }

    /// Indented JSON with sorted keys and a trailing newline.
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
    }
}
