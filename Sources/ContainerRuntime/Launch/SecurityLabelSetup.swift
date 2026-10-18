import SystemPackage

/// AppArmor and SELinux contexts prepared by the supervisor before fork. A
/// requested module that this host does not enable fails here, before any
/// namespace or child exists; a label is never dropped. The child only
/// writes the prepared bytes to its own procfs attributes.
struct SecurityLabelSetup: Sendable {
    /// `exec <profile>`, AppArmor's change-on-exec request.
    let appArmorExec: [UInt8]?
    /// The SELinux context for the workload's execve and for its session
    /// keyring, as runc sets both from the process label.
    let selinuxLabel: [UInt8]?

    /// - Throws: `RuntimeError` when a requested module is not enabled.
    init(_ labels: SecurityLabels) throws {
        if let profile = labels.appArmorProfile {
            guard Kernel.SecurityModule.isAppArmorEnabled else {
                throw RuntimeError("process.apparmorProfile \(profile) is requested, but AppArmor is not enabled on this host")
            }
            appArmorExec = Array("exec \(profile)".utf8)
        } else {
            appArmorExec = nil
        }
        if let label = labels.selinuxLabel {
            guard Kernel.SecurityModule.isSELinuxEnabled else {
                throw RuntimeError("process.selinuxLabel \(label) is requested, but SELinux is disabled or has no policy loaded")
            }
            selinuxLabel = Array(label.utf8)
        } else {
            selinuxLabel = nil
        }
    }

    /// Before joining the session keyring: label the keyring it may create.
    /// Returns nil or the failure.
    func labelKeyCreation() -> LaunchFailure? {
        guard let selinuxLabel else { return nil }
        do {
            try Kernel.SecurityModule.write(.selinuxKeyCreation, selinuxLabel)
            return nil
        } catch {
            return LaunchFailure(stage: .keyCreationLabel, error: error)
        }
    }

    /// Stages both exec contexts; each takes effect at the workload's execve,
    /// so staging them with full privileges before the credential change
    /// enters the same contexts as runc's later writes. Returns nil or the
    /// failure.
    func stageExecContexts() -> LaunchFailure? {
        if let appArmorExec {
            do { try Kernel.SecurityModule.write(.appArmorExec, appArmorExec) }
            // AppArmor reports an unknown profile as ENOENT from the write.
            catch { return LaunchFailure(stage: .appArmorProfile, error: error) }
        }
        if let selinuxLabel {
            do { try Kernel.SecurityModule.write(.selinuxExec, selinuxLabel) }
            catch { return LaunchFailure(stage: .selinuxLabel, error: error) }
        }
        return nil
    }
}
