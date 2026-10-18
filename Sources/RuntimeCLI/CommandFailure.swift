import ArgumentParser
import ContainerRuntime

enum CommandFailure {
    /// Prints a runtime failure and exits with `status`: 1 for lifecycle
    /// commands as in runc, 125 for `run` so it stays distinct from workload exits.
    static func report(_ error: any Error, status: Int32 = 1) -> ExitCode {
        RuntimeDiagnostics.writeError("swift-container-runtime: \(error)")
        return ExitCode(status)
    }
}
