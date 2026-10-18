#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import LinuxAPI
import SystemPackage

extension OCIRunPlan.Namespace {
    var cloneFlag: Int32 {
        switch self {
        case .pid: Int32(CLONE_NEWPID)
        case .mount: Int32(CLONE_NEWNS)
        case .uts: Int32(CLONE_NEWUTS)
        case .ipc: Int32(CLONE_NEWIPC)
        case .network: Int32(CLONE_NEWNET)
        }
    }
}

extension OCIRunPlan.MountFlags {
    var kernelFlags: UInt {
        var flags: UInt = 0
        if contains(.nosuid) { flags |= UInt(MS_NOSUID) }
        if contains(.nodev) { flags |= UInt(MS_NODEV) }
        if contains(.noexec) { flags |= UInt(MS_NOEXEC) }
        if contains(.strictatime) { flags |= UInt(MS_STRICTATIME) }
        return flags
    }
}

/// Group indices in the launch string vector. Each mount adds two groups:
/// its destination components, then `[source, type, data]`.
private enum Group {
    static let arguments = 0, environment = 1, rootfs = 2, hostname = 3, cwdPrefixes = 4, dev = 5, executable = 6
    static func destination(_ mount: Int) -> Int { 7 + 2 * mount }
    static func filesystem(_ mount: Int) -> Int { 8 + 2 * mount }
}

/// Standard character devices, matching runc's default device set.
private let standardDevices: [(name: String, major: UInt32, minor: UInt32)] = [
    ("null", 1, 3), ("zero", 1, 5), ("full", 1, 7), ("random", 1, 8), ("urandom", 1, 9), ("tty", 5, 0),
]

private let standardDevLinks: [(target: String, name: String)] = [
    ("/proc/self/fd", "fd"), ("/proc/self/fd/0", "stdin"), ("/proc/self/fd/1", "stdout"), ("/proc/self/fd/2", "stderr"),
]

extension OCIRunPlan {
    /// Launches the container. Without a gate the init executes the workload
    /// after setup and this returns its status. With a gate (and detached
    /// hooks) the init waits for `start` instead, and this returns 0 once it
    /// has been committed.
    func runOnLinux(hooks: LaunchHooks = LaunchHooks(), gate: StartGate? = nil) throws -> Int32 {
        var groups: [[String]] = [
            arguments,
            environment,
            [rootfs.string],
            hostname.map { [$0] } ?? [],
            cwd.indices.map { "/" + cwd[...$0].joined(separator: "/") },
            ["dev"],
            executable.candidates,
        ]
        for mount in mounts {
            groups.append(mount.destination)
            groups.append([mount.source, mount.type.rawValue, mount.data])
        }
        var strings = try CStringVector(groups: groups)
        let starts = strings.groupStarts
        let flags = namespaces.reduce(Int32(0)) { $0 | $1.cloneFlag }
        let mounts = self.mounts
        let populatesDev = self.populatesDev
        let readonlyRoot = self.readonlyRoot
        let security = self.security
        let searchesPath = executable.searchesPath
        let name = arguments[0]
        // Converted before the fork so the init only borrows the buffer.
        let supplementaryGids = security.additionalGids.map { gid_t($0) }
        // Configured capabilities must exist in the running kernel, whose
        // whole range the init then clears from the bounding set.
        let capabilities = self.capabilities
        let resourceLimits = self.resourceLimits
        let pathControls = self.pathControls
        let lastCapability: Int32
        if let capabilities {
            let last = try kernelLastCapability()
            try capabilities.checkSupported(lastCapability: last)
            lastCapability = Int32(last)
        } else {
            lastCapability = -1
        }
        let context: (LaunchStage, Int32) -> String? = { stage, detail in
            switch stage {
            case .resolveMount, .mount:
                guard mounts.indices.contains(Int(detail)) else { return nil }
                return "\(stage.description) \(mounts[Int(detail)].destinationPath)"
            case .findExecutable, .relativeExecutable: return "process.args[0] \(name): \(stage.description)"
            case .setUserID: return "\(stage.description) \(security.uid)"
            case .setGroupID: return "\(stage.description) \(security.gid)"
            case .dropBoundingCapability:
                return "\(stage.description) \(CapabilitySet.name(of: Int(detail))) (the runtime needs CAP_SETPCAP)"
            case .raiseAmbientCapability:
                return "\(stage.description) \(CapabilitySet.name(of: Int(detail))) (refused by securebits or a missing permitted/inheritable capability)"
            case .setResourceLimit:
                guard resourceLimits.indices.contains(Int(detail)) else { return nil }
                return "\(stage.description)[\(detail)] \(resourceLimits[Int(detail)]) (raising a hard limit needs CAP_SYS_RESOURCE; RLIMIT_NOFILE cannot exceed fs.nr_open)"
            case .resolveReadonlyPath, .readonlyPath, .resolveMaskedPath, .maskPath, .verifyMaskedPath:
                let isMask = stage == .resolveMaskedPath || stage == .maskPath || stage == .verifyMaskedPath
                let paths = isMask ? pathControls.masked : pathControls.readonly
                guard paths.indices.contains(Int(detail)) else { return nil }
                return "\(stage.description) \(paths[Int(detail)])"
            default: return nil
            }
        }
        return unsafe try strings.withPointers { pointers in
            try supplementaryGids.withUnsafeBufferPointer { gidBuffer in
                unsafe try runLaunch(namespaceFlags: flags, hooks: hooks, context: context) { report, commit, launcher in
                    unsafe initializeContainer(
                        strings: pointers, starts: starts, searchesPath: searchesPath, mounts: mounts, populatesDev: populatesDev, readonlyRoot: readonlyRoot,
                        security: security, supplementaryGids: gidBuffer,
                        capabilities: capabilities, lastCapability: lastCapability, resourceLimits: resourceLimits,
                        pathControls: pathControls, foreground: !hooks.detached,
                        report: report, commit: commit, launcher: launcher, gate: gate
                    )
                }
            }
        }
    }
}

/// Runs in the namespace init. Returns only on failure, after reporting it
/// (or, while waiting for start, after the creator has gone).
@unsafe
private func initializeContainer(
    strings: UnsafePointer<UnsafeMutablePointer<CChar>?>,
    starts: [Int],
    searchesPath: Bool,
    mounts: [OCIRunPlan.Mount],
    populatesDev: Bool,
    readonlyRoot: Bool,
    security: OCIRunPlan.ProcessSecurity,
    supplementaryGids: UnsafeBufferPointer<gid_t>,
    capabilities: ProcessCapabilities?,
    lastCapability: Int32,
    resourceLimits: [ResourceLimit],
    pathControls: PathControls,
    foreground: Bool,
    report: borrowing OwnedFileDescriptor,
    commit: borrowing OwnedFileDescriptor,
    launcher: borrowing OwnedFileDescriptor,
    gate: StartGate?
) -> Int32 {
    func group(_ index: Int) -> UnsafePointer<UnsafeMutablePointer<CChar>?> {
        unsafe strings + starts[index]
    }
    let rootfs = unsafe group(Group.rootfs)[0]!

    // Descriptors inherited from the caller (for example a directory outside
    // the rootfs) must not reach the workload. Mark rather than close them, so
    // the CLOEXEC report pipe still works for failures before exec.
    guard linux_mark_descriptors_cloexec(3) == 0 else { return failureStatus(report, .markDescriptors) }

    // The rootfs is trusted input that must not change during setup. Pin the
    // canonical directory, bind it onto its own path (pivot_root needs a mount
    // point; propagation is already rprivate), and confirm that the bind at
    // that path is the pinned directory. This detects a replaced final
    // component; it does not make setup race-free against host processes.
    let pinnedRaw = unsafe linux_open_path(AT_FDCWD, rootfs, O_DIRECTORY | O_NOFOLLOW)
    guard pinnedRaw >= 0 else { return failureStatus(report, .openRootfs) }
    var pinned = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: pinnedRaw))
    let bound = (try? pinned.withDescriptor { descriptor in
        "/proc/self/fd/\(descriptor.rawValue)".withCString { source in
            unsafe mount(source, rootfs, nil, UInt(MS_BIND | MS_REC), nil)
        }
    }) ?? -1
    guard bound == 0 else { return failureStatus(report, .bindRootfs) }
    let rootRaw = unsafe linux_open_path(AT_FDCWD, rootfs, O_DIRECTORY | O_NOFOLLOW)
    guard rootRaw >= 0 else { return failureStatus(report, .openRootfs) }
    var root = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: rootRaw))
    guard let pinnedIdentity = fileIdentity(pinned), let rootIdentity = fileIdentity(root),
          pinnedIdentity == rootIdentity else {
        return failureStatus(report, .verifyRootfs, code: ESTALE)
    }
    try? pinned.close()

    for (index, mount) in mounts.enumerated() {
        let filesystem = unsafe group(Group.filesystem(index))
        if let failure = unsafe mountBeneath(
            root, unsafe group(Group.destination(index)),
            source: unsafe filesystem[0]!, type: unsafe filesystem[1]!, flags: mount.flags.kernelFlags,
            data: unsafe filesystem[2]!
        ) {
            return failureStatus(report, failure.stage, code: failure.code, detail: Int32(index))
        }
    }

    if populatesDev {
        let hasDevpts = mounts.contains { $0.type == .devpts }
        let code = (try? root.withDescriptor { rootDescriptor in
            unsafe withDirectory(beneath: rootDescriptor, unsafe group(Group.dev)) { dev in
                populateDev(dev, linkPtmx: hasDevpts)
            }
        }) ?? EBADF
        guard code == 0 else { return failureStatus(report, .devices, code: code) }
    }

    // pivot_root(".", ".") as in runc: the old root is stacked on the new one
    // and detached through a descriptor, without a put_old directory.
    let oldRaw = unsafe linux_open_path(AT_FDCWD, "/", O_DIRECTORY)
    guard oldRaw >= 0 else { return failureStatus(report, .pivotRoot) }
    var oldRoot = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: oldRaw))
    guard (try? root.withDescriptor({ fchdir($0.rawValue) })) == 0 else { return failureStatus(report, .pivotRoot) }
    guard unsafe linux_pivot_root(".", ".") == 0 else { return failureStatus(report, .pivotRoot) }
    guard (try? oldRoot.withDescriptor({ fchdir($0.rawValue) })) == 0 else { return failureStatus(report, .pivotRoot) }
    guard unsafe umount2(".", Int32(MNT_DETACH)) == 0 else { return failureStatus(report, .pivotRoot) }
    guard unsafe chdir("/") == 0 else { return failureStatus(report, .pivotRoot) }
    try? oldRoot.close()
    try? root.close()

    if let hostname = unsafe group(Group.hostname)[0] {
        guard unsafe sethostname(hostname, strlen(hostname)) == 0 else { return failureStatus(report, .hostname) }
    }

    // Like runc, create a missing cwd. Paths now resolve inside the new root.
    var prefix = unsafe group(Group.cwdPrefixes)
    var directory: UnsafeMutablePointer<CChar>? = nil
    while let path = unsafe prefix[0] {
        guard unsafe mkdir(path, 0o755) == 0 || errno == EEXIST else { return failureStatus(report, .cwd) }
        unsafe directory = path
        unsafe prefix += 1
    }

    // runc's finalizeRootfs: with every mount, /dev entry and the cwd in
    // place, make the root mount read-only. This runs in the container's
    // mount namespace after pivot_root, so it changes only the private bind
    // of the rootfs made above, never the host's mount. It is not recursive:
    // child mounts such as /proc, /dev and a tmpfs keep their own flags.
    if readonlyRoot {
        let code = remountRootReadonly()
        guard code == 0 else { return failureStatus(report, .readonlyRoot, code: code) }
    }
    // runc applies linux.readonlyPaths and then linux.maskedPaths right after
    // finalizeRootfs, and only then enters the cwd and drops privileges, so a
    // cwd below a masked directory is gone and the full privilege of the init
    // performs the mounts.
    if let failure = pathControls.apply() {
        return failureStatus(report, failure.stage, code: failure.code, detail: failure.index)
    }
    return unsafe finishContainerProcess(
        argv: group(Group.arguments), environment: group(Group.environment),
        executables: group(Group.executable), searchesPath: searchesPath, directory: directory,
        security: security, supplementaryGids: supplementaryGids, capabilities: capabilities,
        lastCapability: lastCapability, resourceLimits: resourceLimits, foreground: foreground,
        report: report, commit: commit, launcher: launcher, gate: gate
    )
}

/// Shared process setup for the first workload and later exec processes.
/// The caller has already entered the root and arranged all mounts.
@unsafe
func finishContainerProcess(
    argv: UnsafePointer<UnsafeMutablePointer<CChar>?>,
    environment: UnsafePointer<UnsafeMutablePointer<CChar>?>,
    executables: UnsafePointer<UnsafeMutablePointer<CChar>?>, searchesPath: Bool,
    directory: UnsafeMutablePointer<CChar>?,
    security: OCIRunPlan.ProcessSecurity,
    supplementaryGids: UnsafeBufferPointer<gid_t>,
    capabilities: ProcessCapabilities?, lastCapability: Int32,
    resourceLimits: [ResourceLimit], foreground: Bool,
    report: borrowing OwnedFileDescriptor, commit: borrowing OwnedFileDescriptor,
    launcher: borrowing OwnedFileDescriptor, gate: StartGate?
) -> Int32 {
    // As runc does, enter the cwd with the caller's credentials first and
    // retry after the switch only if they were denied it.
    var enterCwdAsUser = false
    if let directory = unsafe directory, unsafe chdir(directory) != 0 {
        guard errno == EACCES || errno == EPERM else { return failureStatus(report, .cwd) }
        enterCwdAsUser = true
    }

    // runc's order from here: umask (0o022 unless configured), then
    // no_new_privs, then the user (stdio ownership, groups, gid, uid). Every
    // setting is in force before the workload can execute, in either mode.
    _ = umask(mode_t(security.umask))
    if security.noNewPrivileges {
        guard linux_set_no_new_privileges() == 0 else { return failureStatus(report, .noNewPrivileges) }
    }
    // process.rlimits at runc's point: its parent calls prlimit on the init
    // at procReady, after no_new_privs and before finalizeNamespace changes
    // capabilities and credentials. This init is that same process with the
    // caller's credentials, so it sets every entry exactly, in input order,
    // with the same privilege. The rest of setup, a created init's wait, and
    // the start handshake then run under the limits, as runc's init does.
    // A failure fails create or run before readiness.
    if let index = applyResourceLimits(resourceLimits) {
        return failureStatus(report, .setResourceLimit, detail: index)
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
                return failureStatus(report, .dropBoundingCapability, detail: capability)
            }
        }
        guard linux_set_keep_capabilities(1) == 0 else { return failureStatus(report, .keepCapabilities) }
    }
    let stdioCode = giveStdio(to: uid_t(security.uid))
    guard stdioCode == 0 else { return failureStatus(report, .stdioOwnership, code: stdioCode) }
    // setgroups always runs, so an empty list clears the caller's groups;
    // setgid must precede setuid, which gives up the right to change groups.
    // Unless keepcaps was set above, a non-zero uid also loses every capability.
    guard unsafe setgroups(supplementaryGids.count, supplementaryGids.baseAddress) == 0 else {
        return failureStatus(report, .supplementaryGroups)
    }
    guard setgid(gid_t(security.gid)) == 0 else { return failureStatus(report, .setGroupID) }
    guard setuid(uid_t(security.uid)) == 0 else { return failureStatus(report, .setUserID) }
    if enterCwdAsUser, let directory = unsafe directory {
        guard unsafe chdir(directory) == 0 else { return failureStatus(report, .cwd) }
    }

    // Then runc's ApplyCaps: clear keepcaps so exec semantics are standard,
    // install effective/permitted/inheritable exactly (capset also drops
    // ambient capabilities that are no longer permitted and inheritable),
    // and replace whatever ambient set remains with the configured one.
    // Without the object, the inherited sets stay as setuid left them.
    if let capabilities {
        guard linux_set_keep_capabilities(0) == 0 else { return failureStatus(report, .keepCapabilities) }
        guard linux_set_capabilities(
            capabilities.effective.mask, capabilities.permitted.mask, capabilities.inheritable.mask
        ) == 0 else {
            return failureStatus(report, .setCapabilities)
        }
        guard linux_clear_ambient_capabilities() == 0 else { return failureStatus(report, .clearAmbientCapabilities) }
        for capability in stride(from: Int32(0), through: lastCapability, by: 1)
        where capabilities.ambient.contains(Int(capability)) {
            guard linux_raise_ambient_capability(capability) == 0 else {
                return failureStatus(report, .raiseAmbientCapability, detail: capability)
            }
        }
    }

    // The credential change cleared the foreground init's parent-death
    // signal; rearm it and recheck the launcher before going further.
    // A detached init has neither, and stays independent of this process.
    if foreground {
        switch restoreParentDeathSignal(launcher) {
        case true?: break
        case false?: return 125
        case nil: return failureStatus(report, .parentLifetime)
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
            if unsafe executableError(candidate) == 0 {
                unsafe found = candidate
                break
            }
            index += 1
        }
        // Go reports only ErrNotFound for a search, whatever each candidate's
        // error was, and refuses (ErrDot) a first match from a relative or
        // empty PATH element instead of trying later elements.
        guard let found = unsafe found else { return failureStatus(report, .findExecutable, code: 0) }
        guard unsafe found[0] == CChar(UInt8(ascii: "/")) else {
            return failureStatus(report, .relativeExecutable, code: 0)
        }
        unsafe file = found
    } else {
        // An explicit path, absolute or relative to the cwd, reports its own error.
        let lookup = unsafe executableError(executables[0]!)
        guard lookup == 0 else { return failureStatus(report, .execute, code: lookup) }
        unsafe file = executables[0]!
    }

    // An explicit envp replaces the caller's environment entirely.
    if let gate {
        // With every limit in force, a created init that could never accept
        // start (for example under RLIMIT_NOFILE 3) fails create now
        // instead of exiting right after readiness.
        let capacity = gate.acceptCapacityError()
        guard capacity == 0 else { return failureStatus(report, .startDescriptor, code: capacity) }
        guard writeRecord(report, LaunchRecord(.ready)) else { return 125 }
        // EOF instead of the commit: the creator failed or died before
        // recording this init, so nothing could ever start or delete it.
        guard receiveCommit(commit) else { return 125 }
        return unsafe gate.serve(file: file, arguments: argv, environment: environment)
    }
    _ = unsafe execve(file, argv, environment)
    return failureStatus(report, .execute)
}

/// Linux statvfs `f_flag` bits (<linux/statfs.h>) and the mount flags that
/// restate them. Some bits differ (ST_NOSYMFOLLOW is MS_MOVE's value), so
/// the reported flags are translated, not passed through as runc does.
private let preservedMountFlags: [(reported: UInt, flag: UInt)] = [
    (0x2, UInt(MS_NOSUID)), (0x4, UInt(MS_NODEV)), (0x8, UInt(MS_NOEXEC)), (0x2000, 256 /* MS_NOSYMFOLLOW */),
]

/// runc's setReadonly as a single bind remount of "/" with MS_RDONLY. A bind
/// remount sets the mount's per-mount flags to exactly those given, so where
/// runc first tries MS_RDONLY alone (which can clear nosuid, nodev or noexec
/// that the rootfs inherited from its host mount), this restates the flags
/// statvfs reports for "/" from the start. Omitting every atime flag keeps the
/// mount's atime behavior. "/" is the root of the bind made before pivot_root
/// (no configured mount may cover it), and the rootfs filesystem itself is
/// untouched. Returns 0 or errno.
private func remountRootReadonly() -> Int32 {
    var status = statvfs()
    guard unsafe statvfs("/", &status) == 0 else { return errno }
    var flags = UInt(MS_BIND | MS_REMOUNT | MS_RDONLY)
    for entry in preservedMountFlags where UInt(status.f_flag) & entry.reported != 0 {
        flags |= entry.flag
    }
    guard unsafe mount("", "/", nil, flags, nil) == 0 else { return errno }
    return 0
}

/// runc's fixStdioPermissions: stdio inherited from the caller is chowned to
/// the workload uid (the group is kept) so that the workload can reopen it,
/// for example through /dev/stdout. Like runc, this changes the host object
/// (a pipe or terminal); /dev/null and stdio the uid already owns are left
/// alone, and EPERM and EROFS are ignored. Unlike runc, a closed descriptor
/// is skipped. Returns 0 or errno.
private func giveStdio(to uid: uid_t) -> Int32 {
    for descriptor: Int32 in 0...2 {
        var status = stat()
        guard unsafe fstat(descriptor, &status) == 0 else {
            if errno == EBADF { continue }
            return errno
        }
        let isDevNull = status.st_mode & mode_t(LinuxAPI.S_IFMT) == mode_t(LinuxAPI.S_IFCHR)
            && status.st_rdev == deviceNumber(1, 3)
        if status.st_uid == uid || isDevNull { continue }
        guard fchown(descriptor, uid, gid_t.max) == 0 || errno == EPERM || errno == EROFS else { return errno }
    }
    return 0
}

/// runc's setupRlimits: one prlimit per entry, in order, stopping at the
/// first the kernel refuses (EPERM for a raised hard limit without
/// CAP_SYS_RESOURCE or RLIMIT_NOFILE above fs.nr_open). Iterating the
/// prepared array does not allocate. Returns the failing entry's index.
private func applyResourceLimits(_ limits: [ResourceLimit]) -> Int32? {
    for (index, limit) in limits.enumerated() {
        guard linux_set_resource_limit(limit.resource.number, limit.soft, limit.hard) == 0 else {
            return Int32(index)
        }
    }
    return nil
}

/// The highest capability number the running kernel supports.
func kernelLastCapability() throws -> Int {
    let path = "/proc/sys/kernel/cap_last_cap"
    let bytes: [UInt8]?
    do { bytes = try readProcFile(path) } catch { throw RuntimeError("read \(path): \(error)") }
    guard let bytes else { throw RuntimeError("read \(path): file does not exist") }
    return try ProcessCapabilities.parseLastCapability(bytes)
}

/// Go's findExecutable for one candidate, as runc uses it: the file must
/// exist, must not be a directory, and must be executable with the current
/// (already switched) credentials. Returns 0 or errno.
@unsafe
private func executableError(_ path: UnsafePointer<CChar>) -> Int32 {
    var status = stat()
    guard unsafe stat(path, &status) == 0 else { return errno }
    guard status.st_mode & mode_t(LinuxAPI.S_IFMT) != mode_t(LinuxAPI.S_IFDIR) else { return EISDIR }
    guard unsafe access(path, X_OK) == 0 else { return errno }
    return 0
}

/// Mounts a filesystem on a destination resolved beneath `root`.
/// Returns the failing stage and errno, or nil on success.
@unsafe
private func mountBeneath(
    _ root: borrowing OwnedFileDescriptor,
    _ destination: UnsafePointer<UnsafeMutablePointer<CChar>?>,
    source: UnsafePointer<CChar>, type: UnsafePointer<CChar>, flags: UInt, data: UnsafePointer<CChar>
) -> (stage: LaunchStage, code: Int32)? {
    var mountError: Int32 = 0
    let walkError = (try? root.withDescriptor { rootDescriptor in
        unsafe withDirectory(beneath: rootDescriptor, destination) { target in
            // Mount through the descriptor's magic link so the kernel uses
            // exactly the directory resolved above rather than re-walking a path.
            let result = "/proc/self/fd/\(target.rawValue)".withCString { targetPath in
                unsafe mount(source, targetPath, type, flags, unsafe data[0] == 0 ? nil : UnsafeRawPointer(data))
            }
            if result != 0 { mountError = errno }
            return 0
        }
    }) ?? EBADF
    if walkError != 0 { return (.resolveMount, walkError) }
    if mountError != 0 { return (.mount, mountError) }
    return nil
}

/// Walks NULL-terminated directory components beneath `parent`, one
/// `openat(O_PATH|O_DIRECTORY|O_NOFOLLOW)` at a time, creating missing
/// directories. A symlink component fails with ENOTDIR or ELOOP, so the walk
/// never leaves the tree under `parent` (other than through mounts this
/// runtime placed there). Each intermediate descriptor is owned and closed.
/// Returns errno on failure or the body's result.
@unsafe
private func withDirectory(
    beneath parent: FileDescriptor,
    _ components: UnsafePointer<UnsafeMutablePointer<CChar>?>,
    _ body: (FileDescriptor) -> Int32
) -> Int32 {
    guard let name = unsafe components[0] else { return body(parent) }
    let flags = O_DIRECTORY | O_NOFOLLOW
    var raw = unsafe linux_open_path(parent.rawValue, name, flags)
    if raw < 0 && errno == ENOENT {
        guard unsafe mkdirat(parent.rawValue, name, 0o755) == 0 || errno == EEXIST else { return errno }
        raw = unsafe linux_open_path(parent.rawValue, name, flags)
    }
    guard raw >= 0 else { return errno }
    let owner = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
    return (try? owner.withDescriptor { directory in
        unsafe withDirectory(beneath: directory, components + 1, body)
    }) ?? EBADF
}

/// Creates standard device nodes and links in a freshly mounted /dev tmpfs.
/// Returns 0 or errno. Requires CAP_MKNOD; user namespaces are not supported.
private func populateDev(_ dev: FileDescriptor, linkPtmx: Bool) -> Int32 {
    let previousMask = umask(0)
    defer { _ = umask(previousMask) }
    for device in standardDevices {
        let mode = mode_t(LinuxAPI.S_IFCHR) | 0o666
        guard unsafe mknodat(dev.rawValue, device.name, mode, deviceNumber(device.major, device.minor)) == 0 || errno == EEXIST else {
            return errno
        }
    }
    var links = standardDevLinks
    if linkPtmx { links.append((target: "pts/ptmx", name: "ptmx")) }
    for link in links {
        guard unsafe symlinkat(link.target, dev.rawValue, link.name) == 0 || errno == EEXIST else { return errno }
    }
    return 0
}

/// Linux's dev_t encoding (the glibc/musl `makedev` macro is not imported).
func deviceNumber(_ major: UInt32, _ minor: UInt32) -> dev_t {
    let major = UInt64(major), minor = UInt64(minor)
    let value = ((major & 0xffff_f000) << 32) | ((major & 0xfff) << 8) | ((minor & 0xffff_ff00) << 12) | (minor & 0xff)
    return dev_t(value)
}
#endif
