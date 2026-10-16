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

        init(from decoder: any Decoder) throws {
            let object = try StrictObject(decoder, allowed: ["uid", "gid"])
            uid = try object.required("uid")
            gid = try object.required("gid")
        }
    }

    struct Process: Decodable, Sendable {
        var terminal: Bool?
        var user: User?
        var args: [String]
        var env: [String]?
        var cwd: String

        init(from decoder: any Decoder) throws {
            let object = try StrictObject(decoder, allowed: ["terminal", "user", "args", "env", "cwd"])
            terminal = try object.optional("terminal")
            user = try object.optional("user")
            args = try object.required("args")
            env = try object.optional("env")
            cwd = try object.required("cwd")
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

    struct Linux: Decodable, Sendable {
        var namespaces: [Namespace]
        var rootfsPropagation: String?

        init(from decoder: any Decoder) throws {
            let object = try StrictObject(decoder, allowed: ["namespaces", "rootfsPropagation"])
            namespaces = try object.required("namespaces")
            rootfsPropagation = try object.optional("rootfsPropagation")
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

    func optional<Value: Decodable>(_ key: String) throws -> Value? {
        try container.decodeIfPresent(Value.self, forKey: AnyKey(stringValue: key))
    }
}
