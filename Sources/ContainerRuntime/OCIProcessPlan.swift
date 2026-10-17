import SystemPackage

/// Process validation shared by initial launch and exec. This deliberately
/// has no mount or rootfs policy, so standalone process JSON needs no bundle.
struct OCIProcessPlan: Sendable {
    let arguments: [String]
    let environment: [String]
    let cwd: [String]
    let security: OCIRunPlan.ProcessSecurity
    let capabilities: ProcessCapabilities?
    let resourceLimits: [ResourceLimit]

    init(_ process: OCIConfiguration.Process) throws {
        // Validate the requested process before any namespace or child exists.
        guard process.terminal != true else {
            throw RuntimeError("config.json: process.terminal is not implemented; use terminal: false")
        }
        guard let executable = process.args.first, executable.hasPrefix("/") else {
            throw RuntimeError("config.json: process.args[0] must be an absolute path; PATH lookup is not implemented")
        }
        guard process.args.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw RuntimeError("config.json: process.args must not contain NUL")
        }
        // Use exactly the same conversions and constraints for both commands.
        arguments = process.args
        environment = try OCIRunPlan.environment(process.env ?? [])
        cwd = try OCIRunPlan.components(process.cwd, field: "process.cwd")
        security = try OCIRunPlan.security(process)
        capabilities = try process.capabilities.map(ProcessCapabilities.init)
        resourceLimits = try OCIRunPlan.resourceLimits(process.rlimits ?? [])
    }
}
