import ArgumentParser
import ContainerRuntime

/// Converts runtime validation failures into command-line diagnostics.
enum CommandValidation {
    static func id(_ id: String) throws -> ContainerID {
        do {
            return try ContainerID(id)
        } catch {
            throw ValidationError(String(describing: error))
        }
    }

    static func bundle(_ bundle: String) throws {
        guard !bundle.isEmpty, !bundle.utf8.contains(0) else {
            throw ValidationError("bundle path must be non-empty and contain no NUL")
        }
    }

    static func pidFile(_ path: String?) throws {
        guard let path else { return }
        guard !path.utf8.contains(0) else { throw ValidationError("--pid-file must not contain NUL") }
    }

    /// Rejects values runc's dial could not use as a Unix socket address.
    static func pidfdSocket(_ path: String?) throws {
        guard let path else { return }
        do { _ = try PidfdSocketAddress(path) } catch { throw ValidationError("\(error)") }
    }

    /// Rejects negative counts and counts whose first internal descriptor, 3+N, leaves Int32.
    static func preservedDescriptors(_ count: Int) throws -> PreservedDescriptors {
        do { return try PreservedDescriptors(count: count) } catch { throw ValidationError("\(error)") }
    }
}
