import SystemPackage

/// runc's per-container named session keyring (`_ses.<id>`), so the workload
/// never shares the caller's session keys. Init creates it and lets its owner
/// search it; exec joins the same keyring by name. Only the child applies it,
/// before rootfs, credential and seccomp setup; the parent prepares the
/// NUL-terminated name and keeps its own session unchanged.
struct SessionKeyringSetup {
    /// The keyring name, or nil with `--no-new-keyring` (the caller's
    /// session keyring is inherited instead).
    let name: [CChar]?
    /// Exec joins the existing keyring without changing its permissions.
    let isExec: Bool

    init(id: ContainerID, disabled: Bool, isExec: Bool) {
        name = disabled ? nil : Array(("_ses." + id.rawValue).utf8CString)
        self.isExec = isExec
    }

    /// Joins (or creates) the keyring. Returns nil or the failure.
    func apply() -> LaunchFailure? {
        guard let name else { return nil }
        let key: Int32
        do { key = try Kernel.Keyring.joinSession(name) }
        catch { return LaunchFailure(stage: .sessionKeyring, error: error) }
        guard !isExec else { return nil }
        do {
            // No user namespaces yet: keep the existing permissions and add
            // owner search, as runc does, so a later exec can find the keyring.
            let permissions = try Kernel.Keyring.permissions(key)
            try Kernel.Keyring.setPermissions(key, to: permissions | Kernel.Keyring.ownerSearch)
        } catch {
            return LaunchFailure(stage: .keyringPermissions, error: error)
        }
        return nil
    }
}
