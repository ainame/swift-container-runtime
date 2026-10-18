/// The candidate files for process.args[0], prepared before any fork.
///
/// runc resolves args[0] with Go's exec.LookPath (os/exec/lp_unix.go) after
/// entering the cwd and switching credentials, then execs the result with
/// the original argv. This follows that function: a name containing "/" is
/// used as given (relative to the cwd); otherwise each PATH element, with ""
/// meaning ".", is joined with the name and lexically cleaned (Go's
/// filepath.Join). PATH is the workload's own (last entry wins); the
/// caller's PATH is never consulted. A missing or empty PATH has no
/// candidates. The init stops at the first executable candidate and, as Go
/// does without GODEBUG=execerrdot=0, refuses it when it is relative.
/// Deliberate difference: the check uses access(X_OK) after the credential
/// switch rather than Go's faccessat2 with a mode-bit fallback on EPERM.
struct ExecutableLookup: Sendable, Equatable {
    /// Paths tried in order; an explicit path is the only one.
    let candidates: [String]
    /// False for an explicit path, whose own error is reported and which may
    /// be relative. True when the candidates came from PATH.
    let searchesPath: Bool

    init(name: String, environment: [String]) {
        // Bytes, not Characters: a combining mark after "/", ":" or "=" would
        // otherwise merge with it into one Character, unlike Go and Linux.
        if name.utf8.contains(UInt8(ascii: "/")) {
            candidates = [name]
            searchesPath = false
            return
        }
        searchesPath = true
        let entry = environment.last { $0.utf8.starts(with: "PATH=".utf8) }
        let path = entry.map { Array($0.utf8.dropFirst(5)) } ?? []
        // Go's filepath.SplitList: an empty PATH has no elements at all.
        guard !path.isEmpty else {
            candidates = []
            return
        }
        candidates = path.split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false).map { element in
            Self.clean((element.isEmpty ? "." : String(decoding: element, as: UTF8.self)) + "/" + name)
        }
    }

    /// Go's path.Clean for "/"-separated paths, purely lexical.
    static func clean(_ path: String) -> String {
        let rooted = path.utf8.first == UInt8(ascii: "/")
        var parts: [String] = []
        for bytes in path.utf8.split(separator: UInt8(ascii: "/")) {
            let part = String(decoding: bytes, as: UTF8.self)
            switch part {
            case ".": continue
            case "..":
                if let last = parts.last, last != ".." {
                    parts.removeLast()
                } else if !rooted {
                    parts.append(part)
                }
            default: parts.append(part)
            }
        }
        let joined = parts.joined(separator: "/")
        if rooted { return "/" + joined }
        return joined.isEmpty ? "." : joined
    }
}
