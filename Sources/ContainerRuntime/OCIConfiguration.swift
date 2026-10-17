#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The subset of the OCI runtime `config.json` this runtime understands.
///
/// Every object rejects keys outside this subset: an unknown or unimplemented
/// field may change behavior, so silently discarding it would misrepresent
/// what runs. `annotations` is the only free-form map; it does not affect
/// runtime behavior.
struct OCIConfiguration: Decodable, Sendable {
    struct Root: Decodable, Sendable {
        var path: String
        var readonly: Bool?

        init(from decoder: any Decoder) throws {
            let object = try StrictObject(decoder, allowed: ["path", "readonly"])
            path = try object.required("path")
            readonly = try object.optional("readonly")
        }
    }

    struct User: Decodable, Sendable {
        var uid: UInt32
        var gid: UInt32
        var umask: UInt32?
        var additionalGids: [UInt32]?

        init(from decoder: any Decoder) throws {
            // `username` is Windows-only in the OCI specification.
            let object = try StrictObject(decoder, allowed: ["uid", "gid", "umask", "additionalGids"])
            uid = try object.required("uid")
            gid = try object.required("gid")
            umask = try object.optional("umask")
            additionalGids = try object.optional("additionalGids")
        }
    }

    struct Capabilities: Decodable, Sendable {
        var bounding: [String]?
        var effective: [String]?
        var inheritable: [String]?
        var permitted: [String]?
        var ambient: [String]?

        init(from decoder: any Decoder) throws {
            let object = try StrictObject(
                decoder, allowed: ["bounding", "effective", "inheritable", "permitted", "ambient"]
            )
            bounding = try object.optional("bounding")
            effective = try object.optional("effective")
            inheritable = try object.optional("inheritable")
            permitted = try object.optional("permitted")
            ambient = try object.optional("ambient")
        }
    }

    struct Rlimit: Decodable, Sendable {
        var type: String
        var soft: UInt64
        var hard: UInt64

        init(from decoder: any Decoder) throws {
            // runc's Go decoding defaults a missing soft or hard to 0; both
            // are required here instead of silently meaning "no resource".
            let object = try StrictObject(decoder, allowed: ["type", "soft", "hard"])
            type = try object.required("type")
            soft = try object.requiredUInt64("soft")
            hard = try object.requiredUInt64("hard")
        }
    }

    struct Process: Decodable, Sendable {
        var terminal: Bool?
        var user: User?
        var args: [String]
        var env: [String]?
        var cwd: String
        var noNewPrivileges: Bool?
        var capabilities: Capabilities?
        var rlimits: [Rlimit]?

        init(from decoder: any Decoder) throws {
            let object = try StrictObject(
                decoder, allowed: ["terminal", "user", "args", "env", "cwd", "noNewPrivileges", "capabilities", "rlimits"]
            )
            rlimits = try object.optional("rlimits")
            terminal = try object.optional("terminal")
            user = try object.optional("user")
            args = try object.required("args")
            env = try object.optional("env")
            cwd = try object.required("cwd")
            noNewPrivileges = try object.optional("noNewPrivileges")
            capabilities = try object.optional("capabilities")
        }
    }

    struct Mount: Decodable, Sendable {
        var destination: String
        var type: String?
        var source: String?
        var options: [String]?

        init(from decoder: any Decoder) throws {
            let object = try StrictObject(decoder, allowed: ["destination", "type", "source", "options"])
            destination = try object.required("destination")
            type = try object.optional("type")
            source = try object.optional("source")
            options = try object.optional("options")
        }
    }

    struct Namespace: Decodable, Sendable {
        var type: String

        init(from decoder: any Decoder) throws {
            // `path` (joining an existing namespace) is intentionally absent.
            let object = try StrictObject(decoder, allowed: ["type"])
            type = try object.required("type")
        }
    }

    /// `linux.resources.memory`. `kernel`, `kernelTCP`, `swappiness`,
    /// `disableOOMKiller` and `useHierarchy` are not
    /// implemented and therefore rejected.
    struct Memory: Codable, Sendable, Equatable {
        init() {}
        var limit: Int64?
        var reservation: Int64?
        var swap: Int64?
        var checkBeforeUpdate: Bool?

        init(from decoder: any Decoder) throws {
            let object = try StrictObject(decoder, allowed: ["limit", "reservation", "swap", "checkBeforeUpdate"])
            limit = try object.optionalInt64("limit")
            reservation = try object.optionalInt64("reservation")
            swap = try object.optionalInt64("swap")
            checkBeforeUpdate = try object.optional("checkBeforeUpdate")
        }
    }

    struct Pids: Codable, Sendable, Equatable {
        init() {}
        /// Optional since runtime-spec 1.2.1; absent keeps the current value.
        var limit: Int64?

        init(from decoder: any Decoder) throws {
            let object = try StrictObject(decoder, allowed: ["limit"])
            limit = try object.optionalInt64("limit")
        }
    }

    /// `linux.resources.cpu`, with the runtime-spec types: unsigned shares,
    /// period, and burst, signed quota and idle, and CPU/node list strings.
    /// Realtime fields remain unsupported.
    struct CPU: Codable, Sendable, Equatable {
        init() {}
        var shares: UInt64?
        var quota: Int64?
        var burst: UInt64?
        var period: UInt64?
        var idle: Int64?
        var cpus: String?
        var mems: String?

        init(from decoder: any Decoder) throws {
            let object = try StrictObject(decoder, allowed: ["shares", "quota", "burst", "period", "idle", "cpus", "mems"])
            shares = try object.optionalUInt64("shares")
            quota = try object.optionalInt64("quota")
            burst = try object.optionalUInt64("burst")
            period = try object.optionalUInt64("period")
            idle = try object.optionalInt64("idle")
            cpus = try object.optional("cpus")
            mems = try object.optional("mems")
        }
    }

    /// `linux.resources`. Only the memory, pids, and CPU controls are
    /// implemented; block I/O, hugepages, devices, network, RDMA, and unified
    /// keys are rejected rather than ignored.
    struct Resources: Codable, Sendable, Equatable {
        init() {}
        var memory: Memory?
        var pids: Pids?
        var cpu: CPU?

        init(from decoder: any Decoder) throws {
            let object = try StrictObject(decoder, allowed: ["memory", "pids", "cpu"])
            memory = try object.optional("memory")
            pids = try object.optional("pids")
            cpu = try object.optional("cpu")
        }
    }

    struct Linux: Decodable, Sendable {
        var namespaces: [Namespace]
        var rootfsPropagation: String?
        var maskedPaths: [String]?
        var readonlyPaths: [String]?
        var cgroupsPath: String?
        var resources: Resources?

        init(from decoder: any Decoder) throws {
            let object = try StrictObject(
                decoder,
                allowed: ["namespaces", "rootfsPropagation", "maskedPaths", "readonlyPaths", "cgroupsPath", "resources"]
            )
            namespaces = try object.required("namespaces")
            rootfsPropagation = try object.optional("rootfsPropagation")
            maskedPaths = try object.optional("maskedPaths")
            readonlyPaths = try object.optional("readonlyPaths")
            cgroupsPath = try object.optional("cgroupsPath")
            resources = try object.optional("resources")
        }
    }

    var ociVersion: String
    var root: Root
    var process: Process
    var hostname: String?
    var mounts: [Mount]
    var linux: Linux
    var annotations: [String: String]

    init(from decoder: any Decoder) throws {
        let object = try StrictObject(
            decoder, allowed: ["ociVersion", "root", "process", "hostname", "mounts", "linux", "annotations"]
        )
        ociVersion = try object.required("ociVersion")
        root = try object.required("root")
        process = try object.required("process")
        hostname = try object.optional("hostname")
        mounts = try object.optional("mounts") ?? []
        linux = try object.required("linux")
        annotations = try object.optional("annotations") ?? [:]
    }

    static func decode(_ bytes: [UInt8]) throws -> OCIConfiguration {
        do {
            return try JSONDecoder().decode(OCIConfiguration.self, from: Data(bytes))
        } catch let error as RuntimeError {
            throw error
        } catch let DecodingError.keyNotFound(key, context) {
            throw RuntimeError("config.json: missing required field \(fieldPath(context.codingPath + [key]))")
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            throw RuntimeError("config.json: invalid value at \(fieldPath(context.codingPath)): \(context.debugDescription)")
        } catch let DecodingError.dataCorrupted(context) {
            throw RuntimeError("config.json: invalid JSON: \(context.debugDescription)")
        } catch {
            throw RuntimeError("config.json: \(error)")
        }
    }
}

/// A JSON path such as `process.args[0]` for diagnostics.
func fieldPath(_ codingPath: [any CodingKey]) -> String {
    var path = ""
    for key in codingPath {
        if let index = key.intValue {
            path += "[\(index)]"
        } else {
            path += path.isEmpty ? key.stringValue : ".\(key.stringValue)"
        }
    }
    return path.isEmpty ? "<root>" : path
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// A keyed JSON object that rejects keys outside `allowed`.
private struct StrictObject {
    private let container: KeyedDecodingContainer<AnyKey>

    init(_ decoder: any Decoder, allowed: Set<String>) throws {
        container = try decoder.container(keyedBy: AnyKey.self)
        let unknown = container.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            let fields = unknown.map { fieldPath(decoder.codingPath + [AnyKey(stringValue: $0)]) }
            throw RuntimeError("config.json: unsupported field(s): \(fields.joined(separator: ", "))")
        }
    }

    func required<Value: Decodable>(_ key: String) throws -> Value {
        try container.decode(Value.self, forKey: AnyKey(stringValue: key))
    }

    /// A required unsigned 64-bit integer. Missing-key, type-mismatch, and
    /// null errors keep their own diagnostics. Foundation reports a negative,
    /// fractional, or out-of-range JSON number with an internal (non-
    /// DecodingError) error that JSONDecoder later wraps as "not valid JSON"
    /// without a path, or on some versions as pathless corrupted data. This
    /// call decodes only that number, so either is named with its field here.
    func requiredUInt64(_ key: String) throws -> UInt64 {
        do {
            return try container.decode(UInt64.self, forKey: AnyKey(stringValue: key))
        } catch let error as DecodingError {
            guard case .dataCorrupted = error else { throw error }
            throw invalidUInt64(key)
        } catch {
            throw invalidUInt64(key)
        }
    }

    /// An optional unsigned 64-bit integer, with the diagnostics of
    /// `requiredUInt64`.
    func optionalUInt64(_ key: String) throws -> UInt64? {
        do {
            return try container.decodeIfPresent(UInt64.self, forKey: AnyKey(stringValue: key))
        } catch let error as DecodingError {
            guard case .dataCorrupted = error else { throw error }
            throw invalidUInt64(key)
        } catch {
            throw invalidUInt64(key)
        }
    }

    private func invalidUInt64(_ key: String) -> RuntimeError {
        let field = fieldPath(container.codingPath + [AnyKey(stringValue: key)])
        return RuntimeError("config.json: invalid value at \(field): expected an integer from 0 to \(UInt64.max)")
    }

    /// An optional signed 64-bit integer, with the same field-named
    /// diagnostics as `requiredUInt64` for fractional or out-of-range numbers.
    func optionalInt64(_ key: String) throws -> Int64? {
        do {
            return try container.decodeIfPresent(Int64.self, forKey: AnyKey(stringValue: key))
        } catch let error as DecodingError {
            guard case .dataCorrupted = error else { throw error }
            throw invalidInt64(key)
        } catch {
            throw invalidInt64(key)
        }
    }

    private func invalidInt64(_ key: String) -> RuntimeError {
        let field = fieldPath(container.codingPath + [AnyKey(stringValue: key)])
        return RuntimeError("config.json: invalid value at \(field): expected an integer from \(Int64.min) to \(Int64.max)")
    }

    func optional<Value: Decodable>(_ key: String) throws -> Value? {
        try container.decodeIfPresent(Value.self, forKey: AnyKey(stringValue: key))
    }
}
