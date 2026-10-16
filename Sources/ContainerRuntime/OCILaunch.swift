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
    static let arguments = 0, environment = 1, rootfs = 2, hostname = 3, cwdPrefixes = 4, dev = 5
    static func destination(_ mount: Int) -> Int { 6 + 2 * mount }
    static func filesystem(_ mount: Int) -> Int { 7 + 2 * mount }
}

/// Standard character devices, matching runc's default device set.
private let standardDevices: [(name: String, major: UInt32, minor: UInt32)] = [
    ("null", 1, 3), ("zero", 1, 5), ("full", 1, 7), ("random", 1, 8), ("urandom", 1, 9), ("tty", 5, 0),
]

private let standardDevLinks: [(target: String, name: String)] = [
    ("/proc/self/fd", "fd"), ("/proc/self/fd/0", "stdin"), ("/proc/self/fd/1", "stdout"), ("/proc/self/fd/2", "stderr"),
]

extension OCIRunPlan {
    func runOnLinux() throws -> Int32 {
        var groups: [[String]] = [
            arguments,
            environment,
            [rootfs.string],
            hostname.map { [$0] } ?? [],
            cwd.indices.map { "/" + cwd[...$0].joined(separator: "/") },
            ["dev"],
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
        let context: (LaunchStage, Int32) -> String? = { stage, detail in
            guard stage == .resolveMount || stage == .mount, mounts.indices.contains(Int(detail)) else { return nil }
            return "\(stage.description) \(mounts[Int(detail)].destinationPath)"
        }
        return unsafe try strings.withPointers { pointers in
            unsafe try runLaunch(namespaceFlags: flags, context: context) { report in
                unsafe initializeContainer(
                    strings: pointers, starts: starts, mounts: mounts, populatesDev: populatesDev, report: report
                )
            }
        }
    }
}

/// Runs in the namespace init. Returns only on failure, after reporting it.
@unsafe
private func initializeContainer(
    strings: UnsafePointer<UnsafeMutablePointer<CChar>?>,
    starts: [Int],
    mounts: [OCIRunPlan.Mount],
    populatesDev: Bool,
    report: borrowing OwnedFileDescriptor
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
    if let directory = unsafe directory {
        guard unsafe chdir(directory) == 0 else { return failureStatus(report, .cwd) }
    }

    guard setgroups(0, nil) == 0, setgid(0) == 0, setuid(0) == 0 else {
        return failureStatus(report, .identity)
    }

    // An explicit envp replaces the caller's environment entirely.
    let argv = unsafe group(Group.arguments)
    _ = unsafe execve(argv[0]!, argv, group(Group.environment))
    return failureStatus(report, .execute)
}

/// Device and inode numbers of an owned descriptor, or nil if fstat fails.
private func fileIdentity(_ owner: borrowing OwnedFileDescriptor) -> (device: dev_t, inode: ino_t)? {
    try? owner.withDescriptor { descriptor -> (device: dev_t, inode: ino_t)? in
        var status = stat()
        guard unsafe fstat(descriptor.rawValue, &status) == 0 else { return nil }
        return (status.st_dev, status.st_ino)
    }
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
private func deviceNumber(_ major: UInt32, _ minor: UInt32) -> dev_t {
    let major = UInt64(major), minor = UInt64(minor)
    let value = ((major & 0xffff_f000) << 32) | ((major & 0xfff) << 8) | ((minor & 0xffff_ff00) << 12) | (minor & 0xff)
    return dev_t(value)
}
#endif
