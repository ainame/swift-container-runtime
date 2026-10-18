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
    let seccomp: PreparedSeccomp?
    /// AppArmor/SELinux exec contexts staged before the credential change.
    let labels: SecurityLabelSetup
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

        // With no_new_privs, load as late as possible after credential changes
        // and executable lookup. Like runc, create/start still has a short
        // bootstrap handshake under the filter; refused syscalls fail closed.
        if unsafe security.noNewPrivileges, let error = unsafe seccomp?.install() {
            return LaunchRecord.reportFailure(to: report, at: .seccomp, error: error)
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
        let error = unsafe Kernel.Process.execute(file, arguments: argv, environment: environment)
        return LaunchRecord.reportFailure(to: report, at: .execute, error: error)
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
        if let directory = unsafe directory,
           let error = Errno.failure({ () throws(Errno) in try unsafe Kernel.Process.changeDirectory(directory) }) {
            guard error == .permissionDenied || error == .notPermitted else {
                return LaunchRecord.reportFailure(to: report, at: .cwd, error: error)
            }
            enterCwdAsUser = true
        }

        // Inside the container root with full privileges and before
        // no_new_privs. Both contexts apply only at the workload's execve.
        if let failure = unsafe labels.stageExecContexts() {
            return LaunchRecord.reportFailure(to: report, failure)
        }

        // runc's order from here: umask (0o022 unless configured), then
        // no_new_privs, then the user (stdio ownership, groups, gid, uid). Every
        // setting is in force before the workload can execute, in either mode.
        Kernel.Process.setFileCreationMask(UInt32(security.umask))
        if security.noNewPrivileges,
           let error = Errno.failure({ () throws(Errno) in try Kernel.Credentials.setNoNewPrivileges() }) {
            return LaunchRecord.reportFailure(to: report, at: .noNewPrivileges, error: error)
        }
        // process.rlimits at runc's point: its parent calls prlimit on the init
        // at procReady, after no_new_privs and before finalizeNamespace changes
        // capabilities and credentials. This init is that same process with the
        // caller's credentials, so it sets every entry exactly, in input order,
        // with the same privilege. The rest of setup, a created init's wait, and
        // the start handshake then run under the limits, as runc's init does.
        // A failure fails create or run before readiness.
        if let failure = unsafe Self.applyLimits(resourceLimits) {
            return LaunchRecord.reportFailure(to: report, at: .setResourceLimit, error: failure.error, detail: failure.index)
        }
        // Without no_new_privs, filter loading needs CAP_SYS_ADMIN: install
        // before dropping bounding/effective capabilities or switching uid.
        if !security.noNewPrivileges, let error = unsafe seccomp?.install() {
            return LaunchRecord.reportFailure(to: report, at: .seccomp, error: error)
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
                if let error = Errno.failure({ () throws(Errno) in
                    if try Kernel.Credentials.boundingSetContains(capability) {
                        try Kernel.Credentials.dropFromBoundingSet(capability)
                    }
                }) {
                    return LaunchRecord.reportFailure(to: report, at: .dropBoundingCapability, error: error, detail: capability)
                }
            }
            if let error = Errno.failure({ () throws(Errno) in try Kernel.Credentials.setKeepCapabilities(true) }) {
                return LaunchRecord.reportFailure(to: report, at: .keepCapabilities, error: error)
            }
        }
        if let error = unsafe Self.giveStdio(to: uid_t(security.uid)) {
            return LaunchRecord.reportFailure(to: report, at: .stdioOwnership, error: error)
        }
        // setgroups always runs, so an empty list clears the caller's groups;
        // setgid must precede setuid, which gives up the right to change groups.
        // Unless keepcaps was set above, a non-zero uid also loses every capability.
        let groups = unsafe supplementaryGids
        if let error = Errno.failure({ () throws(Errno) in try unsafe Kernel.Credentials.setGroups(groups) }) {
            return LaunchRecord.reportFailure(to: report, at: .supplementaryGroups, error: error)
        }
        if let error = Errno.failure({ () throws(Errno) in try Kernel.Credentials.setGroupID(gid_t(security.gid)) }) {
            return LaunchRecord.reportFailure(to: report, at: .setGroupID, error: error)
        }
        if let error = Errno.failure({ () throws(Errno) in try Kernel.Credentials.setUserID(uid_t(security.uid)) }) {
            return LaunchRecord.reportFailure(to: report, at: .setUserID, error: error)
        }
        if enterCwdAsUser, let directory = unsafe directory,
           let error = Errno.failure({ () throws(Errno) in try unsafe Kernel.Process.changeDirectory(directory) }) {
            return LaunchRecord.reportFailure(to: report, at: .cwd, error: error)
        }

        // Then runc's ApplyCaps: clear keepcaps so exec semantics are standard,
        // install effective/permitted/inheritable exactly (capset also drops
        // ambient capabilities that are no longer permitted and inheritable),
        // and replace whatever ambient set remains with the configured one.
        // Without the object, the inherited sets stay as setuid left them.
        if let capabilities {
            if let error = Errno.failure({ () throws(Errno) in try Kernel.Credentials.setKeepCapabilities(false) }) {
                return LaunchRecord.reportFailure(to: report, at: .keepCapabilities, error: error)
            }
            if let error = Errno.failure({ () throws(Errno) in
                try Kernel.Credentials.setCapabilities(
                    effective: capabilities.effective.mask, permitted: capabilities.permitted.mask,
                    inheritable: capabilities.inheritable.mask)
            }) {
                return LaunchRecord.reportFailure(to: report, at: .setCapabilities, error: error)
            }
            if let error = Errno.failure({ () throws(Errno) in try Kernel.Credentials.clearAmbientCapabilities() }) {
                return LaunchRecord.reportFailure(to: report, at: .clearAmbientCapabilities, error: error)
            }
            for capability in stride(from: Int32(0), through: lastCapability, by: 1)
            where capabilities.ambient.contains(Int(capability)) {
                if let error = Errno.failure({ () throws(Errno) in try Kernel.Credentials.raiseAmbientCapability(capability) }) {
                    return LaunchRecord.reportFailure(to: report, at: .raiseAmbientCapability, error: error, detail: capability)
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
        for raw: Int32 in 0...2 {
            let descriptor = FileDescriptor(rawValue: raw)
            let status: FileStatus
            do {
                status = try Kernel.File.status(of: descriptor)
            } catch .badFileDescriptor {
                continue
            } catch {
                return error
            }
            let isDevNull = status.isCharacterDevice && status.deviceNumber == LinuxDevice.number(1, 3)
            if status.owner == uid || isDevNull { continue }
            do {
                try Kernel.File.changeOwner(descriptor, to: uid)
            } catch .notPermitted, .readOnlyFileSystem {
                continue
            } catch {
                return error
            }
        }
        return nil
    }

    /// runc's setupRlimits: one prlimit per entry, in order, stopping at the
    /// first the kernel refuses (EPERM for a raised hard limit without
    /// CAP_SYS_RESOURCE or RLIMIT_NOFILE above fs.nr_open). Iterating the
    /// prepared array does not allocate. Returns the failing entry's index and error.
    private static func applyLimits(_ limits: [ResourceLimit]) -> (index: Int32, error: Errno)? {
        for (index, limit) in limits.enumerated() {
            do {
                try Kernel.Credentials.setResourceLimit(limit.resource.number, soft: limit.soft, hard: limit.hard)
            } catch {
                return (Int32(index), error)
            }
        }
        return nil
    }

    /// runc's check of one candidate: the file must
    /// exist, must not be a directory, and must be executable with the current
    /// (already switched) credentials. Returns nil or the error.
    @unsafe
    private static func checkExecutable(_ path: UnsafePointer<CChar>) -> Errno? {
        Errno.failure { () throws(Errno) in
            guard try unsafe !Kernel.File.status(atPath: path).isDirectory else { throw .isDirectory }
            try unsafe Kernel.File.checkExecutable(path)
        }
    }
}
