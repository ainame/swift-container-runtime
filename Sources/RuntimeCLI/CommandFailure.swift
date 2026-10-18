import ArgumentParser

/// Keep runtime failures distinct from workload exit codes until the CLI boundary.
struct CommandFailure: Error {
    let message: String
    let status: Int32

    static func report(_ error: any Error, status: Int32 = 1) -> CommandFailure {
        CommandFailure(message: String(describing: error), status: status)
    }
}
