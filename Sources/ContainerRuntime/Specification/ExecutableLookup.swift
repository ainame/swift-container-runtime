import SystemPackage

/// The candidate files for process.args[0], prepared before any fork.
///
/// runc resolves args[0] after entering the cwd and switching credentials,
/// then execs the result with the original argv. The same decisions apply
/// here: a name containing "/" is used as given (relative to the cwd);
/// otherwise each PATH element, with "" meaning ".", is joined with the name
/// and lexically cleaned. PATH is the workload's own (last entry wins); the
/// caller's PATH is never consulted. A missing or empty PATH has no
/// candidates. The init stops at the first executable candidate and, as
/// runc does, refuses it when it is relative. The executable check is
/// access(X_OK) with the switched credentials.
struct ExecutableLookup: Sendable, Equatable {
    /// Paths tried in order; an explicit path is the only one.
    let candidates: [String]
    /// False for an explicit path, whose own error is reported and which may
    /// be relative. True when the candidates came from PATH.
    let searchesPath: Bool

    init(name: String, environment: [String]) {
        // Bytes, not Characters: a combining mark after "/", ":" or "=" would
        // otherwise merge with it into one Character, unlike Linux paths.
        if name.utf8.contains(UInt8(ascii: "/")) {
            candidates = [name]
            searchesPath = false
            return
        }
        searchesPath = true
        let entry = environment.last { $0.utf8.starts(with: "PATH=".utf8) }
        let path = entry.map { Array($0.utf8.dropFirst(5)) } ?? []
        // An empty PATH has no elements at all, not one empty element.
        guard !path.isEmpty else {
            candidates = []
            return
        }
        candidates = path.split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false).map { element in
            Self.clean((element.isEmpty ? "." : String(decoding: element, as: UTF8.self)) + "/" + name)
        }
    }

    /// Lexical cleaning, as runc's lookup applies to each joined candidate.
    /// A path that cleans away entirely is ".", so execve still names the
    /// directory (and fails as runc's does) rather than an empty path.
    static func clean(_ path: String) -> String {
        let cleaned = FilePath(path).lexicallyNormalized().string
        return cleaned.isEmpty ? "." : cleaned
    }
}
