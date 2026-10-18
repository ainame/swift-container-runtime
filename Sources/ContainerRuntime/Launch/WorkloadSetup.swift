#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import LinuxAPI
import SystemPackage

/// Process preparation shared by the first workload and later exec processes.
/// Construct and use only inside the string and supplementary-group buffer scopes.
@unsafe
struct WorkloadSetup {
    let argv: UnsafePointer<UnsafeMutablePointer<CChar>?>
    let environment: UnsafePointer<UnsafeMutablePointer<CChar>?>
    let executables: UnsafePointer<UnsafeMutablePointer<CChar>?>
    let searchesPath: Bool
    let directory: UnsafeMutablePointer<CChar>?
    let security: OCIRunPlan.ProcessSecurity
    let supplementaryGids: UnsafeBufferPointer<gid_t>
    let capabilities: ProcessCapabilities?
    let lastCapability: Int32
    let resourceLimits: [ResourceLimit]
    let foreground: Bool

    /// The caller has entered the root and arranged all mounts.
    @unsafe
    func run(
        report: borrowing OwnedFileDescriptor, commit: borrowing OwnedFileDescriptor,
        launcher: borrowing OwnedFileDescriptor, gate: StartGate?
    ) -> Int32 {
        let foreground = unsafe self.foreground
        let searchesPath = unsafe self.searchesPath
        if let status = unsafe configure(report: report) { return status }

        // The credential change cleared the foreground init's parent-death
        // signal; rearm it and recheck the launcher before going further.
        // A detached init has neither, and stays independent of this process.
        if foreground {
            switch NamespaceLauncher.restoreParentDeathSignal(launcher) {
            case true?: break
            case false?: return 125
            case nil: return LaunchRecord.reportFailure(to: report, at: .parentLifetime)
            }
        }

        // Like runc's create-time exec.LookPath, in the cwd and with the
        // workload's credentials, a missing or non-executable program fails
        // create (or run) rather than start. argv[0] itself is kept; only the
        // execve file is the resolved candidate. Exec can still fail later if
        // the rootfs changes.
        let file: UnsafeMutablePointer<CChar>
        if searchesPath {
            var found: UnsafeMutablePointer<CChar>? = nil
            var index = 0
            while let candidate = unsafe executables[index] {
                if unsafe Self.checkExecutable(candidate) == nil {
                    unsafe found = candidate
                    break
                }
                index += 1
            }
            // Like runc, a search reports only "not found", whatever each
            // candidate's error was, and refuses a first match from a relative
            // or empty PATH element instead of trying later elements.
            guard let found = unsafe found else { return LaunchRecord.reportFailure(to: report, at: .findExecutable, error: nil) }
            guard unsafe found[0] == CChar(UInt8(ascii: "/")) else {
                return LaunchRecord.reportFailure(to: report, at: .relativeExecutable, error: nil)
            }
            unsafe file = found
        } else {
            // An explicit path, absolute or relative to the cwd, reports its own error.
            if let error = unsafe Self.checkExecutable(executables[0]!) {
                return LaunchRecord.reportFailure(to: report, at: .execute, error: error)
            }
            unsafe file = executables[0]!
        }

        // An explicit envp replaces the caller's environment entirely.
        if let gate {
            // With every limit in force, a created init that could never accept
            // start (for example under RLIMIT_NOFILE 3) fails create now
            // instead of exiting right after readiness.
            if let error = gate.acceptCapacityError() {
                return LaunchRecord.reportFailure(to: report, at: .startDescriptor, error: error)
            }
            guard LaunchRecord(.ready).write(to: report) else { return 125 }
            // EOF instead of the commit: the creator failed or died before
            // recording this init, so nothing could ever start or delete it.
            guard (LaunchControl.receive(from: commit) == .commit) else { return 125 }
            return unsafe gate.serve(file: file, arguments: argv, environment: environment)
        }
        _ = unsafe execve(file, argv, environment)
        return LaunchRecord.reportFailure(to: report, at: .execute)
    }

    /// Preserve runc's cwd, limit, capability and credential ordering as one phase.
    @unsafe
    private func configure(report: borrowing OwnedFileDescriptor) -> Int32? {
        let security = unsafe self.security
        let capabilities = unsafe self.capabilities
        let lastCapability = unsafe self.lastCapability
        let resourceLimits = unsafe self.resourceLimits
        // As runc does, enter the cwd with the caller's credentials first and
        // retry after the switch only if they were denied it.
        var enterCwdAsUser = false
        if let directory = unsafe directory, unsafe chdir(directory) != 0 {
            guard errno == EACCES || errno == EPERM else { return LaunchRecord.reportFailure(to: report, at: .cwd) }
            enterCwdAsUser = true
        }

        // runc's order from here: umask (0o022 unless configured), then
        // no_new_privs, then the user (stdio ownership, groups, gid, uid). Every
        // setting is in force before the workload can execute, in either mode.
        _ = umask(mode_t(security.umask))
        if security.noNewPrivileges {
            guard linux_set_no_new_privileges() == 0 else { return LaunchRecord.reportFailure(to: report, at: .noNewPrivileges) }
        }
        // process.rlimits at runc's point: its parent calls prlimit on the init
        // at procReady, after no_new_privs and before finalizeNamespace changes
        // capabilities and credentials. This init is that same process with the
        // caller's credentials, so it sets every entry exactly, in input order,
        // with the same privilege. The rest of setup, a created init's wait, and
        // the start handshake then run under the limits, as runc's init does.
        // A failure fails create or run before readiness.
        if let index = unsafe Self.applyLimits(resourceLimits) {
            return LaunchRecord.reportFailure(to: report, at: .setResourceLimit, detail: index)
        }
        // An explicit process.capabilities follows runc's finalizeNamespace:
        // reduce the bounding set while the init still holds CAP_SETPCAP (the
        // kernel rejects drops later), then keep the permitted set across a
        // non-root setuid so the configured sets can be installed after it.
        if let capabilities {
            for capability in stride(from: Int32(0), through: lastCapability, by: 1)
            where !capabilities.bounding.contains(Int(capability)) {
                // Skip capabilities already absent, so a fully reduced bounding
                // set needs no CAP_SETPCAP.
                let present = linux_read_bounding_capability(capability)
                guard present >= 0, present == 0 || linux_drop_bounding_capability(capability) == 0 else {
                    return LaunchRecord.reportFailure(to: report, at: .dropBoundingCapability, detail: capability)
                }
            }
            guard linux_set_keep_capabilities(1) == 0 else { return LaunchRecord.reportFailure(to: report, at: .keepCapabilities) }
        }
        if let error = unsafe Self.giveStdio(to: uid_t(security.uid)) {
            return LaunchRecord.reportFailure(to: report, at: .stdioOwnership, error: error)
        }
        // setgroups always runs, so an empty list clears the caller's groups;
        // setgid must precede setuid, which gives up the right to change groups.
        // Unless keepcaps was set above, a non-zero uid also loses every capability.
        guard unsafe setgroups(supplementaryGids.count, supplementaryGids.baseAddress) == 0 else {
            return LaunchRecord.reportFailure(to: report, at: .supplementaryGroups)
        }
        guard setgid(gid_t(security.gid)) == 0 else { return LaunchRecord.reportFailure(to: report, at: .setGroupID) }
        guard setuid(uid_t(security.uid)) == 0 else { return LaunchRecord.reportFailure(to: report, at: .setUserID) }
        if enterCwdAsUser, let directory = unsafe directory {
            guard unsafe chdir(directory) == 0 else { return LaunchRecord.reportFailure(to: report, at: .cwd) }
        }

        // Then runc's ApplyCaps: clear keepcaps so exec semantics are standard,
        // install effective/permitted/inheritable exactly (capset also drops
        // ambient capabilities that are no longer permitted and inheritable),
        // and replace whatever ambient set remains with the configured one.
        // Without the object, the inherited sets stay as setuid left them.
        if let capabilities {
            guard linux_set_keep_capabilities(0) == 0 else { return LaunchRecord.reportFailure(to: report, at: .keepCapabilities) }
            guard linux_set_capabilities(
                capabilities.effective.mask, capabilities.permitted.mask, capabilities.inheritable.mask
            ) == 0 else {
                return LaunchRecord.reportFailure(to: report, at: .setCapabilities)
            }
            guard linux_clear_ambient_capabilities() == 0 else { return LaunchRecord.reportFailure(to: report, at: .clearAmbientCapabilities) }
            for capability in stride(from: Int32(0), through: lastCapability, by: 1)
            where capabilities.ambient.contains(Int(capability)) {
                guard linux_raise_ambient_capability(capability) == 0 else {
                    return LaunchRecord.reportFailure(to: report, at: .raiseAmbientCapability, detail: capability)
                }
            }
        }

        return nil
    }

    /// runc's fixStdioPermissions: stdio inherited from the caller is chowned to
    /// the workload uid (the group is kept) so that the workload can reopen it,
    /// for example through /dev/stdout. Like runc, this changes the host object
    /// (a pipe or terminal); /dev/null and stdio the uid already owns are left
    /// alone, and EPERM and EROFS are ignored. Unlike runc, a closed descriptor
    /// is skipped. Returns nil or the error.
    private static func giveStdio(to uid: uid_t) -> Errno? {
        for descriptor: Int32 in 0...2 {
            var status = stat()
            guard unsafe fstat(descriptor, &status) == 0 else {
                if errno == EBADF { continue }
                return .current
            }
            let isDevNull = status.st_mode & mode_t(LinuxAPI.S_IFMT) == mode_t(LinuxAPI.S_IFCHR)
                && UInt64(status.st_rdev) == LinuxDevice.number(1, 3)
            if status.st_uid == uid || isDevNull { continue }
            guard fchown(descriptor, uid, gid_t.max) == 0 || errno == EPERM || errno == EROFS else { return .current }
        }
        return nil
    }

    /// runc's setupRlimits: one prlimit per entry, in order, stopping at the
    /// first the kernel refuses (EPERM for a raised hard limit without
    /// CAP_SYS_RESOURCE or RLIMIT_NOFILE above fs.nr_open). Iterating the
    /// prepared array does not allocate. Returns the failing entry's index.
    private static func applyLimits(_ limits: [ResourceLimit]) -> Int32? {
        for (index, limit) in limits.enumerated() {
            guard linux_set_resource_limit(limit.resource.number, limit.soft, limit.hard) == 0 else {
                return Int32(index)
            }
        }
        return nil
    }

    /// runc's check of one candidate: the file must
    /// exist, must not be a directory, and must be executable with the current
    /// (already switched) credentials. Returns nil or the error.
    @unsafe
    private static func checkExecutable(_ path: UnsafePointer<CChar>) -> Errno? {
        var status = stat()
        guard unsafe stat(path, &status) == 0 else { return .current }
        guard status.st_mode & mode_t(LinuxAPI.S_IFMT) != mode_t(LinuxAPI.S_IFDIR) else { return .isDirectory }
        guard unsafe access(path, X_OK) == 0 else { return .current }
        return nil
    }
}
#endif
