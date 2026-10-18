import SystemPackage

/// Process validation shared by initial launch and exec. This deliberately
/// has no mount or rootfs policy, so standalone process JSON needs no bundle.
struct OCIProcessPlan: Sendable {
    let arguments: [String]
    let environment: [String]
    /// Where the init looks for arguments[0], which is passed unchanged.
    let executable: ExecutableLookup
    let cwd: [String]
    let security: OCIRunPlan.ProcessSecurity
    let capabilities: ProcessCapabilities?
    let resourceLimits: [ResourceLimit]
    /// `process.oomScoreAdj`, validated for both inputs. As in runc, only the
    /// container's value applies: exec reuses the recorded init setting.
    let oomScoreAdjustment: Int32?

    init(_ process: OCIConfiguration.Process) throws {
        // Validate the requested process before any namespace or child exists.
        if let value = process.oomScoreAdj {
            guard (-1000...1000).contains(value) else { throw RuntimeError("config.json: process.oomScoreAdj must be -1000...1000") }
            oomScoreAdjustment = Int32(value)
        } else {
            oomScoreAdjustment = nil
        }
        guard process.terminal != true else {
            throw RuntimeError("config.json: process.terminal is not implemented; use terminal: false")
        }
        guard let name = process.args.first, !name.isEmpty else {
            throw RuntimeError("config.json: process.args[0] must be a non-empty executable name or path")
        }
        guard process.args.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw RuntimeError("config.json: process.args must not contain NUL")
        }
        // Use exactly the same conversions and constraints for both commands.
        arguments = process.args
        environment = try OCIRunPlan.environment(process.env ?? [])
        executable = ExecutableLookup(name: name, environment: environment)
        cwd = try OCIRunPlan.components(process.cwd, field: "process.cwd")
        security = try OCIRunPlan.security(process)
        capabilities = try process.capabilities.map(ProcessCapabilities.init)
        resourceLimits = try OCIRunPlan.resourceLimits(process.rlimits ?? [])
    }
}
