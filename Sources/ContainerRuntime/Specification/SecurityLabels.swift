/// `process.apparmorProfile` and `process.selinuxLabel`: the Linux security
/// module contexts the workload's execve enters. As in runc, an empty string
/// means unset. The container's labels are recorded with its state, so exec
/// never rereads them from a bundle that may have changed.
struct SecurityLabels: Codable, Sendable, Equatable {
    /// The AppArmor profile name, such as `docker-default`.
    var appArmorProfile: String?
    /// The SELinux process context, such as `system_u:system_r:container_t:s0:c1,c2`.
    var selinuxLabel: String?

    init(appArmorProfile: String? = nil, selinuxLabel: String? = nil) {
        self.appArmorProfile = appArmorProfile.flatMap { $0.isEmpty ? nil : $0 }
        self.selinuxLabel = selinuxLabel.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Validated `process` labels.
    /// - Throws: `RuntimeError` for a label containing NUL, which could not
    ///   reach the kernel unchanged.
    init(_ process: OCIConfiguration.Process) throws {
        for (field, value) in [("apparmorProfile", process.apparmorProfile), ("selinuxLabel", process.selinuxLabel)] {
            guard value?.utf8.contains(0) != true else {
                throw RuntimeError("config.json: process.\(field) must not contain NUL")
            }
        }
        self.init(appArmorProfile: process.apparmorProfile, selinuxLabel: process.selinuxLabel)
    }

    /// runc's exec rule: each label set in the exec process replaces the
    /// container's, and an unset one keeps the container's.
    func overridden(by process: SecurityLabels) -> SecurityLabels {
        SecurityLabels(
            appArmorProfile: process.appArmorProfile ?? appArmorProfile,
            selinuxLabel: process.selinuxLabel ?? selinuxLabel)
    }
}
