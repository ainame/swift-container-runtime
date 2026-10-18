#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SystemPackage

/// Runtime status, including runc's cgroup-freezer `paused` extension. It is
/// derived from the live system on every read, never stored.
public enum ContainerStatus: String, Sendable, Codable, CaseIterable {
    /// `create` or `run` is still setting the container up.
    case creating
    /// The init waits for `start`.
    case created
    /// The workload has executed and the init is alive.
    case running
    /// The cgroup freezer has frozen the container.
    case paused
    /// The init has exited (or never existed); only `delete` remains.
    case stopped
}

/// A lifecycle command whose permitted source states follow runc.
public enum LifecycleOperation: Sendable, Equatable {
    case start
    case kill
    case pause
    case resume
    case update
    case delete(force: Bool)

    /// What a permitted operation must do.
    public enum Action: Sendable, Equatable {
        /// Perform the operation itself (start the workload or send a signal).
        case proceed
        /// Kill the verified init, wait for it, then remove the state.
        case killThenDestroy
        /// Remove the state of a stopped container.
        case destroy
    }

    /// Returns the action for `status`, or throws the invalid-transition error.
    ///
    /// As in runc, a plain `delete` of a created container kills its waiting
    /// init; a running container needs `--force`.
    public func action(for status: ContainerStatus, id: ContainerID) throws -> Action {
        switch (self, status) {
        case (.start, .created), (.kill, .created), (.kill, .running), (.kill, .paused),
             (.pause, .created), (.pause, .running), (.resume, .paused),
             (.update, .created), (.update, .running), (.update, .paused):
            return .proceed
        case (.delete, .stopped):
            return .destroy
        case (.delete, .created), (.delete(force: true), .running), (.delete(force: true), .paused), (.delete(force: true), .creating):
            return .killThenDestroy
        default:
            throw LifecycleError.invalidTransition(id: id, operation: verb, status: status)
        }
    }

    /// Whether exec may fork into a container with `status`. runc permits a
    /// paused exec only with `--ignore-paused`; the child then waits on the
    /// frozen cgroup, while this runtime waits for resume before forking.
    enum ExecAdmission: Equatable {
        case proceed
        case waitForResume
        case reject(String)
    }

    static func execAdmission(status: ContainerStatus, ignorePaused: Bool) -> ExecAdmission {
        switch status {
        case .running, .created: .proceed
        case .paused where ignorePaused: .waitForResume
        case .paused: .reject("cannot exec in a paused container (use --ignore-paused to wait for resume)")
        default: .reject("cannot exec in a \(status.rawValue) container")
        }
    }

    private var verb: String {
        switch self {
        case .start: "start"
        case .kill: "kill"
        case .pause: "pause"
        case .resume: "resume"
        case .update: "update"
        case .delete: "delete"
        }
    }
}

/// Lifecycle failures with stable, testable wording.
public enum LifecycleError: Error, Equatable, CustomStringConvertible, Sendable {
    /// `operation` is not permitted while the container has `status`.
    case invalidTransition(id: ContainerID, operation: String, status: ContainerStatus)
    /// No container with this ID exists under the state root.
    case notFound(ContainerID)
    /// A container with this ID already exists.
    case alreadyExists(ContainerID)

    public var description: String {
        switch self {
        case let .invalidTransition(id, operation, status):
            let hint = operation == "delete" && status != .stopped ? " (use --force)" : ""
            return "cannot \(operation) container \(id.rawValue) in the \(status.rawValue) state\(hint)"
        case let .notFound(id):
            return "container \(id.rawValue) does not exist"
        case let .alreadyExists(id):
            return "container \(id.rawValue) already exists"
        }
    }
}

/// The identity of a container init: PID plus `/proc/<pid>/stat` start time
/// (clock ticks since boot) and the kernel boot ID. A PID alone can be reused
/// by an unrelated process after the init exits; the triple cannot.
struct InitIdentity: Codable, Sendable, Equatable {
    var pid: pid_t
    var startTime: UInt64
    var bootID: String
}

/// The persisted `state.json` record. It is written atomically by commands
/// holding the container lock and holds everything later commands need, so
/// the source bundle can be renamed or removed after `create`.
///
/// The status is never stored: it is derived from the init identity, the
/// live process, and the start socket (see `ContainerStatus.derive`).
struct ContainerRecord: Codable, Sendable, Equatable {
    static let currentFormat = 1
    static let maximumBytes = 1 << 20

    var format: Int
    var id: String
    var ociVersion: String
    var bundle: String
    var rootfs: String
    var created: String
    var annotations: [String: String]
    /// Whether the init has its own PID namespace; the init must then not
    /// share the caller's PID namespace when it is signaled.
    var pidNamespace: Bool
    /// Absent while creating (or after an aborted create).
    var initProcess: InitIdentity?
    /// The container's cgroup, recorded right after it is prepared and
    /// before any init exists. Absent in records written before cgroup
    /// support (which created none) and before preparation.
    var cgroup: CgroupIdentity?
    /// Security policy for every later exec, independent of bundle mutations.
    /// Nil also reads legacy records written before seccomp support.
    var seccomp: SeccompProfile?
    /// Explicit keyring opt-out for init and exec. Nil in legacy records
    /// preserves their previous inherited-session behavior on exec.
    var noNewKeyring: Bool?
    /// Original container OOM score, reused even for standalone-process exec.
    var oomScoreAdjustment: Int32?
    /// Container AppArmor/SELinux labels that exec inherits unless its
    /// process overrides them. Nil in legacy records, which had none.
    var securityLabels: SecurityLabels?
    /// Raw resource configuration, independent of the source bundle. Nil
    /// distinguishes legacy records from new containers with empty settings.
    var resourceConfiguration: OCIConfiguration.Resources?

    /// `created` is recorded as RFC 3339 UTC with millisecond precision.
    init(id: ContainerID, plan: OCIRunPlan, created: Date = Date(), noNewKeyring: Bool = false) {
        format = Self.currentFormat
        self.id = id.rawValue
        ociVersion = plan.ociVersion
        bundle = plan.bundle.string
        rootfs = plan.rootfs.string
        self.created = created.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        annotations = plan.annotations
        pidNamespace = plan.namespaces.contains(.pid)
        initProcess = nil
        cgroup = nil
        resourceConfiguration = plan.resourceConfiguration
        seccomp = plan.seccomp
        self.noNewKeyring = noNewKeyring
        oomScoreAdjustment = plan.oomScoreAdjustment
        securityLabels = plan.securityLabels
    }

    func encoded() throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Array(try encoder.encode(self))
    }

    /// Decodes and validates a record read from the directory named `id`.
    /// Malformed state must never name the caller, PID 1, or a path-relative
    /// bundle, so every field is checked here rather than at each use.
    static func decode(_ bytes: [UInt8], expectedID id: ContainerID) throws -> ContainerRecord {
        // Decode the complete record before validating its identity and paths.
        let record: ContainerRecord
        do {
            record = try JSONDecoder().decode(ContainerRecord.self, from: Data(bytes))
        } catch {
            throw RuntimeError("state of container \(id.rawValue) is corrupt: \(error)")
        }
        func corrupt(_ reason: String) -> RuntimeError {
            RuntimeError("state of container \(id.rawValue) is corrupt: \(reason)")
        }
        // Metadata must belong to this directory and use absolute persisted paths.
        guard record.format == currentFormat else { throw corrupt("unsupported format \(record.format)") }
        guard record.id == id.rawValue else { throw corrupt("it names container \(record.id)") }
        for path in [record.bundle, record.rootfs] {
            guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw corrupt("paths must be absolute") }
        }
        // Never allow malformed state to become a broad or privileged signal target.
        if let process = record.initProcess {
            guard process.pid > 1 else { throw corrupt("invalid init PID \(process.pid)") }
            guard process.startTime > 0 else { throw corrupt("invalid init start time") }
            guard InitIdentity.isValidBootID(process.bootID) else { throw corrupt("invalid boot ID") }
        }
        if let score = record.oomScoreAdjustment, !(-1000...1000).contains(score) {
            throw corrupt("invalid OOM score adjustment")
        }
        // A cgroup record must never name the mount root or leave it.
        if let cgroup = record.cgroup, !cgroup.isValid { throw corrupt("invalid cgroup \(cgroup.path)") }
        return record
    }
}

/// The OCI state of one container, as printed by `state` and `list`.
public struct ContainerStateReport: Sendable, Equatable {
    /// The OCI runtime specification version of the bundle's `config.json`.
    public let ociVersion: String
    /// The container ID.
    public let id: String
    /// The live status.
    public let status: ContainerStatus
    /// The init's host PID (`pid_t`), kept while paused; 0 when stopped, as in runc.
    public let pid: Int32
    /// The absolute bundle directory.
    public let bundle: String
    /// The absolute root filesystem directory.
    public let rootfs: String
    /// The creation time, RFC 3339 in UTC with millisecond precision.
    public let created: String
    /// The `config.json` annotations.
    public let annotations: [String: String]
    /// The state directory owner, shown only by `list`.
    public let owner: String

    init(record: ContainerRecord?, id: ContainerID, status: ContainerStatus, owner: String) {
        ociVersion = record?.ociVersion ?? ""
        self.id = id.rawValue
        self.status = status
        pid = status == .stopped || status == .creating ? 0 : record?.initProcess?.pid ?? 0
        bundle = record?.bundle ?? ""
        rootfs = record?.rootfs ?? ""
        created = record?.created ?? ""
        annotations = record?.annotations ?? [:]
        self.owner = owner
    }

    /// Pretty-printed JSON with sorted keys; `annotations` is omitted when
    /// empty, as runc does.
    public func stateJSON() throws -> String {
        try Self.encode(Document(self, includeOwner: false), pretty: true)
    }

    /// A JSON array on one line, or `null` when empty, as in runc.
    public static func listJSON(_ reports: [ContainerStateReport]) throws -> String {
        if reports.isEmpty { return "null" }
        return try encode(reports.map { Document($0, includeOwner: true) }, pretty: false)
    }

    /// runc's table layout: columns padded to the widest cell plus three
    /// spaces with a minimum width of 12, and no padding after the last column.
    public static func table(_ reports: [ContainerStateReport]) -> String {
        let header = ["ID", "PID", "STATUS", "BUNDLE", "CREATED", "OWNER"]
        let rows = [header] + reports.map {
            [$0.id, String($0.pid), $0.status.rawValue, $0.bundle, $0.created, $0.owner]
        }
        // Compute shared column widths before rendering rows.
        var widths = Array(repeating: 12, count: header.count - 1)
        for row in rows {
            for column in widths.indices {
                widths[column] = max(widths[column], row[column].count + 3)
            }
        }
        // Keep the last column unpadded so table output has no trailing spaces.
        return rows.map { row in
            var line = ""
            for column in widths.indices {
                line += row[column] + String(repeating: " ", count: widths[column] - row[column].count)
            }
            return line + row[row.count - 1] + "\n"
        }.joined()
    }

    private static func encode(_ value: some Encodable, pretty: Bool) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted] : [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private struct Document: Encodable {
        let report: ContainerStateReport
        let includeOwner: Bool

        init(_ report: ContainerStateReport, includeOwner: Bool) {
            self.report = report
            self.includeOwner = includeOwner
        }

        enum Key: String, CodingKey {
            case ociVersion, id, pid, status, bundle, rootfs, created, annotations, owner
        }

        func encode(to encoder: any Encoder) throws {
            var object = encoder.container(keyedBy: Key.self)
            try object.encode(report.ociVersion, forKey: .ociVersion)
            try object.encode(report.id, forKey: .id)
            try object.encode(report.pid, forKey: .pid)
            try object.encode(report.status.rawValue, forKey: .status)
            try object.encode(report.bundle, forKey: .bundle)
            try object.encode(report.rootfs, forKey: .rootfs)
            try object.encode(report.created, forKey: .created)
            if !report.annotations.isEmpty { try object.encode(report.annotations, forKey: .annotations) }
            if includeOwner { try object.encode(report.owner, forKey: .owner) }
        }
    }
}

/// Fields of `/proc/<pid>/stat` used to identify a process.
struct ProcessStat: Equatable {
    /// The state letter, such as `R`, `S`, or `Z`.
    var state: UInt8
    /// Field 22: start time in clock ticks after boot.
    var startTime: UInt64

    /// The command name (field 2) may contain spaces and parentheses, so the
    /// remaining fields start after its last `)`.
    init?(parsing bytes: [UInt8]) {
        guard let close = bytes.lastIndex(of: UInt8(ascii: ")")) else { return nil }
        let fields = bytes[(close + 1)...].split(separator: UInt8(ascii: " "), omittingEmptySubsequences: true)
        // fields[0] is field 3 (state); field 22 is fields[19].
        guard fields.count > 19, fields[0].count == 1,
              let startTime = UInt64(String(decoding: fields[19], as: UTF8.self)) else { return nil }
        state = fields[0].first!
        self.startTime = startTime
    }

    /// Zombie (`Z`) and dead (`X`/`x`) processes have exited.
    var hasExited: Bool {
        state == UInt8(ascii: "Z") || state == UInt8(ascii: "X") || state == UInt8(ascii: "x")
    }
}

/// Linux signal names and numbers (identical on x86_64 and arm64).
public enum SignalName {
    static let numbers: [String: Int32] = [
        "HUP": 1, "INT": 2, "QUIT": 3, "ILL": 4, "TRAP": 5, "ABRT": 6, "IOT": 6, "BUS": 7, "FPE": 8,
        "KILL": 9, "USR1": 10, "SEGV": 11, "USR2": 12, "PIPE": 13, "ALRM": 14, "TERM": 15,
        "STKFLT": 16, "CHLD": 17, "CONT": 18, "STOP": 19, "TSTP": 20, "TTIN": 21, "TTOU": 22,
        "URG": 23, "XCPU": 24, "XFSZ": 25, "VTALRM": 26, "PROF": 27, "WINCH": 28, "IO": 29,
        "POLL": 29, "PWR": 30, "SYS": 31,
    ]

    /// The signal number for `text`: a name with or without `SIG` in any case
    /// (`TERM`, `sigkill`) or a number in 0...64.
    ///
    /// - Returns: A Linux signal number for ``ContainerLifecycle/kill(id:signal:)``.
    /// - Throws: `RuntimeError` for an unknown name or an out-of-range number.
    public static func parse(_ text: String) throws -> Int32 {
        if let number = Int32(text) {
            guard (0...64).contains(number) else { throw RuntimeError("signal number \(text) is outside 0...64") }
            return number
        }
        var name = text.uppercased()
        if name.hasPrefix("SIG") { name.removeFirst(3) }
        guard text.unicodeScalars.allSatisfy(\.isASCII), let number = numbers[name] else {
            throw RuntimeError("unknown signal \"\(text)\"")
        }
        return number
    }
}


extension ContainerStatus {
    /// Status from the live system rather than from stored text, as runc's
    /// refreshState does: a record without an init is creating while its creator
    /// holds the lock and stopped otherwise; a recorded init that no longer
    /// matches its identity is stopped; a live init is created until it consumes
    /// the start socket and running afterwards, unless its cgroup is frozen.
    static func derive(hasInit: Bool, initAlive: Bool, creatorActive: Bool, startSocketPresent: Bool, frozen: Bool = false) -> ContainerStatus {
        guard hasInit else { return creatorActive ? .creating : .stopped }
        guard initAlive else { return .stopped }
        if frozen { return .paused }
        return startSocketPresent ? .created : .running
    }
}

extension InitIdentity {
    /// Kernel boot IDs are UUID strings; anything else is treated as corrupt.
    static func isValidBootID(_ value: String) -> Bool {
        value.utf8.count == 36 && value.utf8.allSatisfy { byte in
            byte == UInt8(ascii: "-") || (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}
