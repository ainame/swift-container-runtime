#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import LinuxAPI
import SystemPackage

/// Group indices in the launch string vector. Each mount adds two groups:
/// its destination components, then `[source, type, data]`.
enum InitStringGroup {
    static let arguments = 0, environment = 1, rootfs = 2, hostname = 3, cwdPrefixes = 4, dev = 5, executable = 6
    static func destination(_ mount: Int) -> Int { 7 + 2 * mount }
    static func filesystem(_ mount: Int) -> Int { 8 + 2 * mount }
}

/// Prepared init inputs; every borrowed string remains within the enclosing launch scope.
@unsafe
struct RootFilesystemSetup {
    let strings: UnsafePointer<UnsafeMutablePointer<CChar>?>
    let starts: [Int]
    let mounts: [OCIRunPlan.Mount]
    let populatesDev: Bool
    let readonlyRoot: Bool
    let pathControls: PathControls

    /// Runs after namespace creation, before credentials and workload execution.
    /// Returns nil on success, or the child exit status after reporting a failure.
    @unsafe
    func prepare(report: borrowing OwnedFileDescriptor) -> Int32? {
        let mounts = unsafe self.mounts
        let populatesDev = unsafe self.populatesDev
        let readonlyRoot = unsafe self.readonlyRoot
        let pathControls = unsafe self.pathControls
        func group(_ index: Int) -> UnsafePointer<UnsafeMutablePointer<CChar>?> {
            unsafe strings + starts[index]
        }
        let rootfs = unsafe group(InitStringGroup.rootfs)[0]!

        // The rootfs is trusted input that must not change during setup. Pin the
        // canonical directory, bind it onto its own path (pivot_root needs a mount
        // point; propagation is already rprivate), and confirm that the bind at
        // that path is the pinned directory. This detects a replaced final
        // component; it does not make setup race-free against host processes.
        let pinnedRaw = unsafe linux_open_path(AT_FDCWD, rootfs, O_DIRECTORY | O_NOFOLLOW)
        guard pinnedRaw >= 0 else { return LaunchRecord.reportFailure(to: report, at: .openRootfs) }
        var pinned = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: pinnedRaw))
        let bound = (try? pinned.withDescriptor { descriptor in
            "/proc/self/fd/\(descriptor.rawValue)".withCString { source in
                unsafe LinuxAPI.mount(source, rootfs, nil, UInt(MS_BIND | MS_REC), nil)
            }
        }) ?? -1
        guard bound == 0 else { return LaunchRecord.reportFailure(to: report, at: .bindRootfs) }
        let rootRaw = unsafe linux_open_path(AT_FDCWD, rootfs, O_DIRECTORY | O_NOFOLLOW)
        guard rootRaw >= 0 else { return LaunchRecord.reportFailure(to: report, at: .openRootfs) }
        var root = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: rootRaw))
        guard let pinnedIdentity = pinned.identity(), let rootIdentity = root.identity(),
              pinnedIdentity == rootIdentity else {
            return LaunchRecord.reportFailure(to: report, at: .verifyRootfs, code: ESTALE)
        }
        try? pinned.close()

        for (index, mount) in mounts.enumerated() {
            let filesystem = unsafe group(InitStringGroup.filesystem(index))
            if let failure = unsafe Self.mount(
                root, unsafe group(InitStringGroup.destination(index)),
                source: unsafe filesystem[0]!, type: unsafe filesystem[1]!, flags: mount.flags.kernelFlags,
                data: unsafe filesystem[2]!
            ) {
                return LaunchRecord.reportFailure(to: report, at: failure.stage, code: failure.code, detail: Int32(index))
            }
        }

        if populatesDev {
            let hasDevpts = mounts.contains { $0.type == .devpts }
            let code = (try? root.withDescriptor { rootDescriptor in
                unsafe Self.withDirectory(beneath: rootDescriptor, unsafe group(InitStringGroup.dev)) { dev in
                    unsafe Self.populateDevices(dev, linkPtmx: hasDevpts)
                }
            }) ?? EBADF
            guard code == 0 else { return LaunchRecord.reportFailure(to: report, at: .devices, code: code) }
        }

        // pivot_root(".", ".") as in runc: the old root is stacked on the new one
        // and detached through a descriptor, without a put_old directory.
        let oldRaw = unsafe linux_open_path(AT_FDCWD, "/", O_DIRECTORY)
        guard oldRaw >= 0 else { return LaunchRecord.reportFailure(to: report, at: .pivotRoot) }
        var oldRoot = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: oldRaw))
        guard (try? root.withDescriptor({ fchdir($0.rawValue) })) == 0 else { return LaunchRecord.reportFailure(to: report, at: .pivotRoot) }
        guard unsafe linux_pivot_root(".", ".") == 0 else { return LaunchRecord.reportFailure(to: report, at: .pivotRoot) }
        guard (try? oldRoot.withDescriptor({ fchdir($0.rawValue) })) == 0 else { return LaunchRecord.reportFailure(to: report, at: .pivotRoot) }
        guard unsafe umount2(".", Int32(MNT_DETACH)) == 0 else { return LaunchRecord.reportFailure(to: report, at: .pivotRoot) }
        guard unsafe chdir("/") == 0 else { return LaunchRecord.reportFailure(to: report, at: .pivotRoot) }
        try? oldRoot.close()
        try? root.close()

        if let hostname = unsafe group(InitStringGroup.hostname)[0] {
            guard unsafe sethostname(hostname, strlen(hostname)) == 0 else { return LaunchRecord.reportFailure(to: report, at: .hostname) }
        }

        // Like runc, create a missing cwd. Paths now resolve inside the new root.
        var prefix = unsafe group(InitStringGroup.cwdPrefixes)
        while let path = unsafe prefix[0] {
            guard unsafe mkdir(path, 0o755) == 0 || errno == EEXIST else { return LaunchRecord.reportFailure(to: report, at: .cwd) }
            unsafe prefix += 1
        }

        // runc's finalizeRootfs: with every mount, /dev entry and the cwd in
        // place, make the root mount read-only. This runs in the container's
        // mount namespace after pivot_root, so it changes only the private bind
        // of the rootfs made above, never the host's mount. It is not recursive:
        // child mounts such as /proc, /dev and a tmpfs keep their own flags.
        if readonlyRoot {
            let code = unsafe Self.makeReadonly()
            guard code == 0 else { return LaunchRecord.reportFailure(to: report, at: .readonlyRoot, code: code) }
        }
        // runc applies linux.readonlyPaths and then linux.maskedPaths right after
        // finalizeRootfs, and only then enters the cwd and drops privileges, so a
        // cwd below a masked directory is gone and the full privilege of the init
        // performs the mounts.
        if let failure = pathControls.apply() {
            return LaunchRecord.reportFailure(to: report, at: failure.stage, code: failure.code, detail: failure.index)
        }
        return nil
    }

    /// runc's setReadonly as a single bind remount of "/" with MS_RDONLY. A bind
    /// remount sets the mount's per-mount flags to exactly those given, so where
    /// runc first tries MS_RDONLY alone (which can clear nosuid, nodev or noexec
    /// that the rootfs inherited from its host mount), this restates the flags
    /// statvfs reports for "/" from the start. Omitting every atime flag keeps the
    /// mount's atime behavior. "/" is the root of the bind made before pivot_root
    /// (no configured mount may cover it), and the rootfs filesystem itself is
    /// untouched. Returns 0 or errno.
    private static func makeReadonly() -> Int32 {
        var status = statvfs()
        guard unsafe statvfs("/", &status) == 0 else { return errno }
        var flags = UInt(MS_BIND | MS_REMOUNT | MS_RDONLY)
        for entry in unsafe preservedMountFlags where UInt(status.f_flag) & entry.reported != 0 {
            flags |= entry.flag
        }
        guard unsafe LinuxAPI.mount("", "/", nil, flags, nil) == 0 else { return errno }
        return 0
    }

    /// Mounts a filesystem on a destination resolved beneath `root`.
    /// Returns the failing stage and errno, or nil on success.
    @unsafe
    private static func mount(
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
                    unsafe LinuxAPI.mount(source, targetPath, type, flags, unsafe data[0] == 0 ? nil : UnsafeRawPointer(data))
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
    private static func withDirectory(
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
    private static func populateDevices(_ dev: FileDescriptor, linkPtmx: Bool) -> Int32 {
        let previousMask = umask(0)
        defer { _ = umask(previousMask) }
        for device in unsafe standardDevices {
            let mode = mode_t(LinuxAPI.S_IFCHR) | 0o666
            guard unsafe mknodat(dev.rawValue, device.name, mode, LinuxDevice.number(device.major, device.minor)) == 0 || errno == EEXIST else {
                return errno
            }
        }
        var links = unsafe standardDevLinks
        if linkPtmx { links.append((target: "pts/ptmx", name: "ptmx")) }
        for link in links {
            guard unsafe symlinkat(link.target, dev.rawValue, link.name) == 0 || errno == EEXIST else { return errno }
        }
        return 0
    }

    /// Standard character devices, matching runc's default device set.
    private static let standardDevices: [(name: String, major: UInt32, minor: UInt32)] = [
        ("null", 1, 3), ("zero", 1, 5), ("full", 1, 7), ("random", 1, 8), ("urandom", 1, 9), ("tty", 5, 0),
    ]

    private static let standardDevLinks: [(target: String, name: String)] = [
        ("/proc/self/fd", "fd"), ("/proc/self/fd/0", "stdin"), ("/proc/self/fd/1", "stdout"), ("/proc/self/fd/2", "stderr"),
    ]

    /// Linux statvfs `f_flag` bits (<linux/statfs.h>) and the mount flags that
    /// restate them. Some bits differ (ST_NOSYMFOLLOW is MS_MOVE's value), so
    /// the reported flags are translated, not passed through as runc does.
    private static let preservedMountFlags: [(reported: UInt, flag: UInt)] = [
        (0x2, UInt(MS_NOSUID)), (0x4, UInt(MS_NODEV)), (0x8, UInt(MS_NOEXEC)), (0x2000, 256 /* MS_NOSYMFOLLOW */),
    ]
}
#endif
