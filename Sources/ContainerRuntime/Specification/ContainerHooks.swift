/// OCI `hooks`, validated and recorded with the container so that `start`
/// and `delete` run poststart and poststop hooks without rereading a bundle
/// that may have changed or been removed.
struct ContainerHooks: Codable, Sendable, Equatable {
    /// The six hook phases, in the order a container passes through them.
    enum Phase: String, CaseIterable, Sendable {
        case prestart, createRuntime, createContainer, startContainer, poststart, poststop
    }

    /// One hook: an executable at an absolute path with its argv, environment
    /// and an optional timeout in seconds.
    struct Hook: Codable, Sendable, Equatable {
        let path: String
        let args: [String]?
        let env: [String]?
        let timeout: Int?

        /// argv: `args`, or just the path when absent or empty, as Go's exec
        /// does for runc.
        var argv: [String] { args.flatMap { $0.isEmpty ? nil : $0 } ?? [path] }
        var duration: Duration? { timeout.map { .seconds($0) } }

        init(from decoder: any Decoder) throws {
            let object = try StrictObject(decoder, allowed: ["path", "args", "env", "timeout"])
            path = try object.required("path")
            args = try object.optional("args")
            env = try object.optional("env")
            timeout = try object.optional("timeout")
        }
    }

    var prestart: [Hook] = []
    var createRuntime: [Hook] = []
    var createContainer: [Hook] = []
    var startContainer: [Hook] = []
    var poststart: [Hook] = []
    var poststop: [Hook] = []

    init() {}

    init(from decoder: any Decoder) throws {
        let object = try StrictObject(decoder, allowed: Set(Phase.allCases.map(\.rawValue)))
        prestart = try object.optional("prestart") ?? []
        createRuntime = try object.optional("createRuntime") ?? []
        createContainer = try object.optional("createContainer") ?? []
        startContainer = try object.optional("startContainer") ?? []
        poststart = try object.optional("poststart") ?? []
        poststop = try object.optional("poststop") ?? []
    }

    subscript(phase: Phase) -> [Hook] {
        switch phase {
        case .prestart: prestart
        case .createRuntime: createRuntime
        case .createContainer: createContainer
        case .startContainer: startContainer
        case .poststart: poststart
        case .poststop: poststop
        }
    }

    var isEmpty: Bool { Phase.allCases.allSatisfy { self[$0].isEmpty } }

    /// At most this many hooks per phase, so an init-side failure can name
    /// its hook in a launch record.
    static let maximumPerPhase = 255

    /// - Throws: `RuntimeError` naming the first invalid hook: a relative path,
    ///   NUL in any string, or a timeout that is not positive.
    func validated() throws -> ContainerHooks {
        for phase in Phase.allCases {
            let hooks = self[phase]
            guard hooks.count <= Self.maximumPerPhase else {
                throw RuntimeError("config.json: hooks.\(phase.rawValue) has more than \(Self.maximumPerPhase) hooks")
            }
            for (index, hook) in hooks.enumerated() {
                let field = "config.json: hooks.\(phase.rawValue)[\(index)]"
                guard hook.path.hasPrefix("/") else { throw RuntimeError("\(field).path must be absolute") }
                let strings = [hook.path] + (hook.args ?? []) + (hook.env ?? [])
                guard strings.allSatisfy({ !$0.utf8.contains(0) }) else { throw RuntimeError("\(field) must not contain NUL") }
                if let timeout = hook.timeout, timeout <= 0 { throw RuntimeError("\(field).timeout must be positive") }
            }
        }
        return self
    }
}
