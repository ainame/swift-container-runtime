import SystemPackage

/// Group indices in the launch string vector. `sysctls` alternates procfs
/// paths and values. Each mount adds three groups: its destination
/// components, `[source, type, data]`, and the absolute destination prefixes
/// a bind resolves in-root (empty for other mounts).
enum InitStringGroup {
    static let arguments = 0, environment = 1, rootfs = 2, hostname = 3, cwdPrefixes = 4, dev = 5, executable = 6
    static let sysctls = 7
    static func destination(_ mount: Int) -> Int { 8 + 3 * mount }
    static func filesystem(_ mount: Int) -> Int { 9 + 3 * mount }
    static func destinationPrefixes(_ mount: Int) -> Int { 10 + 3 * mount }
}

/// Prepared init inputs; every borrowed string remains within the enclosing launch scope.
@unsafe
struct RootFilesystemSetup {
    let strings: UnsafePointer<UnsafeMutablePointer<CChar>?>
    let starts: [Int]
    let mounts: [OCIRunPlan.Mount]
    let populatesDev: Bool
    let readonlyRoot: Bool
    /// Final propagation for the root bind, isolated from the host before setup.
    let rootPropagation: OCIRunPlan.BindPropagation
    let pathControls: PathControls
    /// `process.terminal`: set up once the new root is in place.
    let terminal: TerminalSetup?
    /// Pause after the mounts for the supervisor's prestart/createRuntime hooks.
    var runsRuntimeHooks = false
    /// createContainer hooks, run in this mount namespace before pivot_root.
    var createContainerHooks: InitHooks = unsafe .none

    /// Runs after namespace creation, before credentials and workload execution.
    /// Returns nil on success, or the child exit status after reporting a failure.
    @unsafe
    func prepare(report: borrowing OwnedFileDescriptor, commit: borrowing OwnedFileDescriptor) -> Int32? {
        guard let failure = unsafe prepareSteps(report: report, commit: commit) else { return nil }
        return LaunchRecord.reportFailure(to: report, failure)
    }

    /// The setup steps in runc's order; each returns its failure.
    @unsafe
    private func prepareSteps(report: borrowing OwnedFileDescriptor, commit: borrowing OwnedFileDescriptor) -> LaunchFailure? {
        let sources: [BindMountSource?]
        do { sources = try unsafe pinBindSources() }
        catch { return error }
        let rootfs = unsafe group(InitStringGroup.rootfs)[0]!
        var root = OwnedFileDescriptor()
        if let failure = unsafe Self.bindRootfs(rootfs, pinningInto: &root) { return failure }
        if let failure = unsafe mountAll(beneath: root, sources: sources) { return failure }
        if unsafe populatesDev, let failure = unsafe populateDev(beneath: root) { return failure }
        // runc's procHooks: with every mount in place, the supervisor runs
        // prestart and createRuntime hooks while this init waits.
        if unsafe runsRuntimeHooks {
            guard LaunchRecord(.runtimeHooks).write(to: report), LaunchControl.receive(from: commit) == .proceed else {
                return LaunchFailure(stage: .runtimeHooks, error: nil)
            }
        }
        // createContainer hooks run here, before pivot_root, with the rootfs
        // as the working directory, as in runc.
        if unsafe !createContainerHooks.hooks.isEmpty {
            if let error = root.failure(in: { root in Errno.failure { () throws(Errno) in try Kernel.Process.changeDirectory(to: root) } }) {
                return HookOutcome.spawnFailed(error).failure(at: .createContainerHook, index: 0)
            }
            if let failure = unsafe createContainerHooks.run() { return failure }
        }
        if let failure = unsafe Self.switchRoot(to: root) { return failure }
        // pivot_root refuses a shared new root. Set its final propagation only
        // after pivot, then restore explicit child modes that a recursive root
        // mode may have reset. All targets are now resolved inside the new root.
        if let error = Errno.failure({ () throws(Errno) in
            try unsafe Kernel.Mount.mount(source: nil, target: "/", type: nil, flags: rootPropagation.kernelFlags)
        }) { return LaunchFailure(stage: .propagation, error: error) }
        for (index, mount) in unsafe mounts.enumerated() {
            guard let propagation = mount.propagation else { continue }
            let error = mount.destinationPath.withCString { path in
                Errno.failure { () throws(Errno) in
                    try unsafe Kernel.Mount.mount(source: nil, target: path, type: nil, flags: propagation.kernelFlags)
                }
            }
            if let error { return LaunchFailure(stage: .mount, error: error, detail: Int32(index)) }
        }

        // runc's setupConsole: after every configured mount, so /dev/pts is
        // the container's, and before the root may become read-only.
        if let failure = unsafe terminal?.setUp() { return failure }
        if let hostname = unsafe group(InitStringGroup.hostname)[0],
           let error = Errno.failure({ () throws(Errno) in try unsafe Kernel.Process.setHostname(hostname) }) {
            return LaunchFailure(stage: .hostname, error: error)
        }
        if let failure = unsafe writeSysctls() { return failure }
        if let failure = unsafe makeWorkingDirectory() { return failure }
        // runc's finalizeRootfs: with every mount, /dev entry and the cwd in
        // place, make the root mount read-only. This runs in the container's
        // mount namespace after pivot_root, so it changes only the private bind
        // of the rootfs made above, never the host's mount. It is not recursive:
        // child mounts such as /proc, /dev and a tmpfs keep their own flags.
        if unsafe readonlyRoot, let error = unsafe Self.makeReadonly() {
            return LaunchFailure(stage: .readonlyRoot, error: error)
        }
        // runc applies linux.readonlyPaths and then linux.maskedPaths right after
        // finalizeRootfs, and only then enters the cwd and drops privileges, so a
        // cwd below a masked directory is gone and the full privilege of the init
        // performs the mounts.
        return unsafe pathControls.apply()
    }

    @unsafe
    private func group(_ index: Int) -> UnsafePointer<UnsafeMutablePointer<CChar>?> {
        unsafe strings + starts[index]
    }

    /// The rootfs is trusted input that must not change during setup. Pin the
    /// canonical directory, bind it onto its own path (pivot_root needs a mount
    /// point; propagation is already rprivate), and confirm that the bind at
    /// that path is the pinned directory. This detects a replaced final
    /// component; it does not make setup race-free against host processes.
    @unsafe
    private static func bindRootfs(_ rootfs: UnsafePointer<CChar>, pinningInto root: inout OwnedFileDescriptor) -> LaunchFailure? {
        var pinned = OwnedFileDescriptor()
        if let error = Errno.failure({ () throws(Errno) in
            pinned = try unsafe Kernel.File.openPath(rootfs, options: [.directory, .noFollow])
        }) {
            return LaunchFailure(stage: .openRootfs, error: error)
        }
        let bindError = pinned.failure(in: { descriptor in
            "/proc/self/fd/\(descriptor.rawValue)".withCString { source in
                Errno.failure { () throws(Errno) in
                    try unsafe Kernel.Mount.mount(source: source, target: rootfs, type: nil, flags: [.bind, .recursive])
                }
            }
        })
        if let bindError { return LaunchFailure(stage: .bindRootfs, error: bindError) }
        if let error = Errno.failure({ () throws(Errno) in
            root = try unsafe Kernel.File.openPath(rootfs, options: [.directory, .noFollow])
        }) {
            return LaunchFailure(stage: .openRootfs, error: error)
        }
        guard let pinnedIdentity = pinned.identity(), let rootIdentity = root.identity(), pinnedIdentity == rootIdentity else {
            return LaunchFailure(stage: .verifyRootfs, error: .staleNFSFileHandle)
        }
        return nil
    }

    /// Pins every bind source by its host path before any configured mount
    /// could hide that path.
    @unsafe
    private func pinBindSources() throws(LaunchFailure) -> [BindMountSource?] {
        var sources: [BindMountSource?] = []
        for (index, mount) in unsafe mounts.enumerated() {
            guard mount.type == .bind else {
                sources.append(nil)
                continue
            }
            do {
                sources.append(try unsafe BindMountSource(path: group(InitStringGroup.filesystem(index))[0]!))
            } catch {
                throw LaunchFailure(stage: .openMountSource, error: error, detail: Int32(index))
            }
        }
        return sources
    }

    /// The configured mounts in order, each on a destination resolved beneath `root`.
    @unsafe
    private func mountAll(beneath root: borrowing OwnedFileDescriptor, sources: [BindMountSource?]) -> LaunchFailure? {
        for (index, mount) in unsafe mounts.enumerated() {
            let destination = unsafe group(InitStringGroup.destination(index))
            let failure: LaunchFailure?
            if let source = sources[index] {
                failure = unsafe source.attach(
                    mount, components: destination, prefixes: group(InitStringGroup.destinationPrefixes(index)), beneath: root)
            } else {
                let filesystem = unsafe group(InitStringGroup.filesystem(index))
                failure = unsafe Self.mount(
                    root, destination, source: unsafe filesystem[0]!, type: unsafe filesystem[1]!,
                    flags: mount.flags.kernelFlags, data: unsafe filesystem[2]!, propagation: mount.propagation)
            }
            if var failure {
                failure.detail = Int32(index)
                return failure
            }
        }
        return nil
    }

    /// Standard device nodes and links in the container's /dev.
    @unsafe
    private func populateDev(beneath root: borrowing OwnedFileDescriptor) -> LaunchFailure? {
        let hasDevpts = unsafe mounts.contains { $0.type == .devpts }
        let dev = unsafe group(InitStringGroup.dev)
        let error = root.failure(in: { rootDescriptor in
            unsafe Self.withDirectory(beneath: rootDescriptor, dev) { dev in
                unsafe Self.populateDevices(dev, linkPtmx: hasDevpts)
            }
        })
        return error.map { LaunchFailure(stage: .devices, error: $0) }
    }

    /// pivot_root(".", ".") as in runc: the old root is stacked on the new one
    /// and detached through a descriptor, without a put_old directory. Both
    /// descriptors are closed afterwards.
    private static func switchRoot(to root: consuming OwnedFileDescriptor) -> LaunchFailure? {
        do {
            try unsafe pivot(into: root)
        } catch {
            return LaunchFailure(stage: .pivotRoot, error: error)
        }
        try? root.close()
        return nil
    }

    private static func pivot(into root: borrowing OwnedFileDescriptor) throws(Errno) {
        var oldRoot = try Kernel.File.openPath("/", options: .directory)
        defer { try? oldRoot.close() }
        try root.borrowDescriptor { root throws(Errno) in try Kernel.Process.changeDirectory(to: root) }
        try unsafe Kernel.Mount.pivotRoot(".", ".")
        try oldRoot.borrowDescriptor { oldRoot throws(Errno) in try Kernel.Process.changeDirectory(to: oldRoot) }
        try unsafe Kernel.Mount.unmountDetached(".")
        try unsafe Kernel.Process.changeDirectory("/")
    }

    /// runc's sysctl step: each entry through the container's /proc/sys,
    /// which must be procfs, in key order. Returns nil or the failure.
    @unsafe
    private func writeSysctls() -> LaunchFailure? {
        var entry = unsafe group(InitStringGroup.sysctls)
        var index: Int32 = 0
        while let path = unsafe entry[0], let value = unsafe entry[1] {
            do {
                try unsafe Kernel.File.writeProcFile(path, value)
            } catch {
                return LaunchFailure(stage: .sysctl, error: error, detail: index)
            }
            unsafe entry += 2
            index += 1
        }
        return nil
    }

    /// Like runc, create a missing cwd. Paths now resolve inside the new root.
    @unsafe
    private func makeWorkingDirectory() -> LaunchFailure? {
        var prefix = unsafe group(InitStringGroup.cwdPrefixes)
        while let path = unsafe prefix[0] {
            do {
                try unsafe Kernel.File.makeDirectory(path, permissions: FilePermissions(rawValue: 0o755))
            } catch .fileExists {
            } catch {
                return LaunchFailure(stage: .cwd, error: error)
            }
            unsafe prefix += 1
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
    /// untouched. Returns nil or the error.
    private static func makeReadonly() -> Errno? {
        Errno.failure { () throws(Errno) in
            let reported = try unsafe Kernel.Mount.statusFlags(ofPath: "/")
            var flags: MountFlags = [.bind, .remount, .readOnly]
            for entry in unsafe preservedMountFlags where reported & entry.reported != 0 {
                flags.insert(entry.flag)
            }
            try unsafe Kernel.Mount.mount(source: "", target: "/", type: nil, flags: flags)
        }
    }

    /// Mounts a filesystem on a destination resolved beneath `root`.
    /// Returns nil or the failure.
    @unsafe
    private static func mount(
        _ root: borrowing OwnedFileDescriptor,
        _ destination: UnsafePointer<UnsafeMutablePointer<CChar>?>,
        source: UnsafePointer<CChar>, type: UnsafePointer<CChar>, flags: MountFlags, data: UnsafePointer<CChar>,
        propagation: OCIRunPlan.BindPropagation?
    ) -> LaunchFailure? {
        var mountError: Errno? = nil
        let walkError = root.failure(in: { rootDescriptor in
            unsafe withDirectory(beneath: rootDescriptor, destination) { target in
                // Mount through the descriptor's magic link so the kernel uses
                // exactly the directory resolved above rather than re-walking a path.
                mountError = "/proc/self/fd/\(target.rawValue)".withCString { targetPath in
                    Errno.failure { () throws(Errno) in
                        try unsafe Kernel.Mount.mount(
                            source: source, target: targetPath, type: type, flags: flags,
                            data: unsafe data[0] == 0 ? nil : UnsafeRawPointer(data))

                    }
                }
                return nil
            }
        })
        if let walkError { return LaunchFailure(stage: .resolveMount, error: walkError) }
        if let mountError { return LaunchFailure(stage: .mount, error: mountError) }
        if let propagation {
            let error = root.failure(in: { rootDescriptor in
                unsafe withDirectory(beneath: rootDescriptor, destination) { mounted in
                    "/proc/self/fd/\(mounted.rawValue)".withCString { path in
                        Errno.failure { () throws(Errno) in
                            try unsafe Kernel.Mount.mount(source: nil, target: path, type: nil, flags: propagation.kernelFlags)
                        }
                    }
                }
            })
            if let error { return LaunchFailure(stage: .mount, error: error) }
        }
        return nil
    }

    /// Walks NULL-terminated directory components beneath `parent`, one
    /// O_PATH|O_DIRECTORY|O_NOFOLLOW open at a time, creating missing
    /// directories. A symlink component fails with ENOTDIR or ELOOP, so the walk
    /// never leaves the tree under `parent` (other than through mounts this
    /// runtime placed there). Each intermediate descriptor is owned and closed.
    /// Returns the walk's error or the body's result.
    @unsafe
    private static func withDirectory(
        beneath parent: FileDescriptor,
        _ components: UnsafePointer<UnsafeMutablePointer<CChar>?>,
        _ body: (FileDescriptor) -> Errno?
    ) -> Errno? {
        guard let name = unsafe components[0] else { return body(parent) }
        var directory = OwnedFileDescriptor()
        if let error = Errno.failure({ () throws(Errno) in directory = try unsafe openOrCreateDirectory(name, in: parent) }) {
            return error
        }
        return directory.failure(in: { unsafe withDirectory(beneath: $0, components + 1, body) })
    }

    /// The directory `name` in `parent`, created first when it is missing.
    @unsafe
    private static func openOrCreateDirectory(_ name: UnsafePointer<CChar>, in parent: FileDescriptor) throws(Errno) -> OwnedFileDescriptor {
        do {
            return try unsafe Kernel.File.openPath(name, in: parent, options: [.directory, .noFollow])
        } catch .noSuchFileOrDirectory {
        }
        do {
            try unsafe Kernel.File.makeDirectory(name, in: parent, permissions: FilePermissions(rawValue: 0o755))
        } catch .fileExists {
        }
        return try unsafe Kernel.File.openPath(name, in: parent, options: [.directory, .noFollow])
    }

    /// Creates standard device nodes and links in a freshly mounted /dev tmpfs.
    /// Returns nil or the error. Requires CAP_MKNOD; user namespaces are not supported.
    private static func populateDevices(_ dev: FileDescriptor, linkPtmx: Bool) -> Errno? {
        let previousMask = Kernel.Process.setFileCreationMask(0)
        defer { Kernel.Process.setFileCreationMask(previousMask) }
        return Errno.failure { () throws(Errno) in try unsafe makeDevices(in: dev, linkPtmx: linkPtmx) }
    }

    private static func makeDevices(in dev: FileDescriptor, linkPtmx: Bool) throws(Errno) {
        for device in unsafe standardDevices {
            do {
                try unsafe Kernel.File.makeCharacterDevice(
                    device.name, in: dev, permissions: FilePermissions(rawValue: 0o666),
                    device: LinuxDevice.number(device.major, device.minor))
            } catch .fileExists {
            }
        }
        var links = unsafe standardDevLinks
        if linkPtmx { links.append((target: "pts/ptmx", name: "ptmx")) }
        for link in links {
            do {
                try unsafe Kernel.File.makeSymbolicLink(link.name, to: link.target, in: dev)
            } catch .fileExists {
            }
        }
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
    private static let preservedMountFlags: [(reported: UInt, flag: MountFlags)] = [
        (0x2, .noSetUserID), (0x4, .noDevices), (0x8, .noExecute), (0x2000, .noSymbolicLinkFollow),
    ]
}
