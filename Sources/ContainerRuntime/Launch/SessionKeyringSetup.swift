import SystemPackage

/// runc's named session: init creates/adjusts permissions; exec joins it.
/// Only the child applies it, before rootfs/credentials/seccomp setup. The
/// parent prepares the NUL-terminated name and keeps its own session unchanged.
struct SessionKeyringSetup {
    let name: [CChar]?
    let isExec: Bool

    init(id: ContainerID, disabled: Bool, isExec: Bool) {
        name = disabled ? nil : Array(("_ses." + id.rawValue).utf8CString)
        self.isExec = isExec
    }

    func apply() -> LaunchFailure? {
        guard let name else { return nil }
        let key: Int32
        do { key = try Kernel.Keyring.joinSession(name) }
        catch { return LaunchFailure(stage: .sessionKeyring, error: error) }
        guard !isExec else { return nil }
        do {
            // No user namespaces yet: preserve existing permissions and add
            // owner search, as runc does. Exec can then find this named ring.
            let permissions = try Kernel.Keyring.permissions(key)
            try Kernel.Keyring.setPermissions(key, to: permissions | 0x00080000)
        } catch {
            return LaunchFailure(stage: .keyringPermissions, error: error)
        }
        return nil
    }
}
