import SystemPackage

/// Diagnostics the runtime prints itself, outside thrown errors.
public enum RuntimeDiagnostics {
    /// Writes `message` and a newline to standard error, ignoring failures.
    public static func writeError(_ message: String) {
        _ = try? FileDescriptor.standardError.writeAll((message + "\n").utf8)
    }
}
