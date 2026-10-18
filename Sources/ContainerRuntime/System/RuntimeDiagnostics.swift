import SystemPackage

public enum RuntimeDiagnostics {
    public static func writeError(_ message: String) {
        _ = try? FileDescriptor.standardError.writeAll((message + "\n").utf8)
    }
}
