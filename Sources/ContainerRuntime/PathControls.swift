#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
#if os(Linux)
import LinuxAPI
#endif

/// `linux.readonlyPaths` and `linux.maskedPaths` as absolute container paths.
///
/// Paths are checked lexically like other container paths (`.` and `..` are
/// rejected rather than cleaned) and stored in their canonical `/a/b` form;
/// `/` itself is a valid entry, as in runc. Read-only paths keep their input
/// order and repeats, because runc binds a repeated path again (visible in
/// mountinfo). A masked path repeated with the same canonical spelling is
/// applied once, like runc's lexical deduplication; symlink aliases of one
/// target are not merged, as in runc. Entries are resolved one at a time
/// against the tree the previous entries left, so a path below a masked
/// directory is then missing.
public struct PathControls: Sendable, Equatable {
    public let readonly: [String]
    public let masked: [String]

    init(readonly: [String], masked: [String]) throws {
        self.readonly = try Self.paths(readonly, field: "linux.readonlyPaths", deduplicate: false)
        self.masked = try Self.paths(masked, field: "linux.maskedPaths", deduplicate: true)
    }

    private static func paths(_ entries: [String], field: String, deduplicate: Bool) throws -> [String] {
        var seen = Set<String>()
        var kept: [String] = []
        for (index, entry) in entries.enumerated() {
            let components = try OCIRunPlan.components(entry, field: "\(field)[\(index)]")
            let path = "/" + components.joined(separator: "/")
            if !deduplicate || seen.insert(path).inserted { kept.append(path) }
        }
        return kept
    }
}

#if os(Linux)
struct PathControlFailure {
    let stage: LaunchStage
    let code: Int32
    /// Index into `readonly` or `masked`, or -1 for the shared setup.
    let index: Int32
}

extension PathControls {
    /// runc's readonlyPath loop, then its maskPaths, in the init after
    /// pivot_root and the read-only root remount.
    ///
    /// Each path is opened beneath the container root with
    /// openat2(RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS): a symlink is followed
    /// as runc follows it from inside the container, but `..` and absolute
    /// targets stay below the root, and a magic link (which could name an
    /// inherited host descriptor) fails setup with ELOOP instead of being
    /// followed or skipped. Mounts are then made with the descriptor-based
    /// mount API on those descriptors, so no path string is walked again and
    /// no /proc mount is needed. A missing path is skipped, as in runc; any
    /// other error fails setup. Every descriptor opened here is close-on-exec
    /// and closed before returning.
    ///
    /// Limits: only this init uses the container's new mount namespace during
    /// setup, so no other process can add mounts between these steps. A host
    /// process that can rename entries in the rootfs could still redirect a
    /// later lookup to another file *inside* the container root; the file
    /// identity checks below detect a replaced target but do not make setup
    /// race-free against such a writer. The rootfs is assumed to have a single
    /// owner during setup, as for the rest of the rootfs preparation.
    func apply() -> PathControlFailure? {
        let root = unsafe linux_open_path(AT_FDCWD, "/", O_DIRECTORY)
        guard root >= 0 else { return PathControlFailure(stage: .resolveReadonlyPath, code: errno, index: -1) }
        defer { _ = close(root) }
        for (index, path) in readonly.enumerated() {
            if let failure = Self.makeReadonly(path, root: root) {
                return PathControlFailure(stage: failure.stage, code: failure.code, index: Int32(index))
            }
        }
        return mask(root: root)
    }

    /// runc's maskPaths: a non-directory gets the container's /dev/null bound
    /// over it; a directory gets an empty read-only tmpfs. As in runc, the
    /// first directory's tmpfs is bound onto later directories, so they share
    /// one inode, and after a failed bind each later directory gets its own.
    /// Unlike runc, every mask is checked to be what the path now shows, so a
    /// mask hidden from the container (for example one stacked on `/`) fails
    /// setup instead of silently leaving the path unmasked.
    private func mask(root: Int32) -> PathControlFailure? {
        guard !masked.isEmpty else { return nil }
        // runc's verifyDevNull: even when every masked path is missing, the
        // container's /dev/null must be the 1:3 character device.
        let devNull = unsafe linux_open_path_in_root(root, "/dev/null", 0)
        guard devNull >= 0 else { return PathControlFailure(stage: .openDevNull, code: errno, index: -1) }
        defer { _ = close(devNull) }
        guard let devNullStatus = Self.fileStatus(devNull) else {
            return PathControlFailure(stage: .openDevNull, code: errno, index: -1)
        }
        guard Self.isType(devNullStatus, LinuxAPI.S_IFCHR), devNullStatus.st_rdev == deviceNumber(1, 3) else {
            return PathControlFailure(stage: .openDevNull, code: ENODEV, index: -1)
        }

        // The first directory mask's mount descriptor, kept as the source of
        // later directory binds; closed before returning.
        var shared: Int32 = -1
        var sharedBindFailed = false
        defer { if shared >= 0 { _ = close(shared) } }
        for (index, path) in masked.enumerated() {
            let failure = { (stage: LaunchStage, code: Int32) in
                PathControlFailure(stage: stage, code: code, index: Int32(index))
            }
            let target = unsafe linux_open_path_in_root(root, path, 0)
            guard target >= 0 else {
                if errno == ENOENT { continue }
                return failure(.resolveMaskedPath, errno)
            }
            defer { _ = close(target) }
            guard let status = Self.fileStatus(target) else { return failure(.maskPath, errno) }

            // Attach the mask and remember the file it must show.
            let expected: stat
            if !Self.isType(status, LinuxAPI.S_IFDIR) {
                let code = Self.attachClone(of: devNull, onto: target, recursive: false)
                guard code == 0 else { return failure(.maskPath, code) }
                expected = devNullStatus
            } else if shared >= 0, !sharedBindFailed, Self.attachClone(of: shared, onto: target, recursive: false) == 0 {
                guard let sharedStatus = Self.fileStatus(shared) else { return failure(.maskPath, errno) }
                expected = sharedStatus
            } else {
                // A shared bind failing makes every later directory use its own tmpfs.
                if shared >= 0 { sharedBindFailed = true }
                let mask = Self.openMaskTmpfs()
                guard mask >= 0 else { return failure(.maskPath, -mask) }
                let keep = shared < 0 && !sharedBindFailed
                defer { if !keep { _ = close(mask) } }
                if keep { shared = mask }
                guard let maskStatus = Self.fileStatus(mask) else { return failure(.maskPath, errno) }
                guard linux_attach_mount(mask, target) == 0 else { return failure(.maskPath, errno) }
                expected = maskStatus
            }

            // The path, resolved again, must now show the mask itself.
            let shown = unsafe linux_open_path_in_root(root, path, 0)
            guard shown >= 0 else { return failure(.verifyMaskedPath, errno) }
            defer { _ = close(shown) }
            guard let shownStatus = Self.fileStatus(shown), Self.isSameFile(shownStatus, expected) else {
                return failure(.verifyMaskedPath, EBUSY)
            }
        }
        return nil
    }
}

private extension PathControls {
    /// runc's readonlyPath: `mount(path, path, MS_BIND|MS_REC)`, skipped when
    /// the path is missing, then `mount(path, path, MS_BIND|MS_REMOUNT|MS_RDONLY)`
    /// with the statfs-reported nosuid/nodev/noexec flags. The remount acts on
    /// whatever mount the path reaches after the bind: normally the new bind,
    /// but which mount a lookup ending at `/` reaches is the kernel's lookup
    /// decision, made here exactly as for runc's path string by resolving the
    /// path again. mount_setattr then sets only the read-only attribute, so
    /// nosuid, nodev, noexec, nosymfollow and atime stay as they were, and mounts
    /// below the bind keep their own flags. Returns nil or the failing stage and errno.
    static func makeReadonly(_ path: String, root: Int32) -> (stage: LaunchStage, code: Int32)? {
        let target = unsafe linux_open_path_in_root(root, path, 0)
        guard target >= 0 else { return errno == ENOENT ? nil : (.resolveReadonlyPath, errno) }
        defer { _ = close(target) }
        guard let original = fileStatus(target) else { return (.readonlyPath, errno) }
        let code = attachClone(of: target, onto: target, recursive: true)
        guard code == 0 else { return (.readonlyPath, code) }

        // A bind shows the same file, so a different one means the path was
        // replaced between the lookups. This does not prove which mount the
        // second lookup reached; see PathControls.apply.
        let reached = unsafe linux_open_path_in_root(root, path, 0)
        guard reached >= 0 else { return (.readonlyPath, errno) }
        defer { _ = close(reached) }
        guard let status = fileStatus(reached), isSameFile(status, original) else { return (.readonlyPath, ESTALE) }
        guard linux_set_mount_readonly(reached) == 0 else { return (.readonlyPath, errno) }
        return nil
    }

    /// runc's maskDir as a detached mount: an empty tmpfs with one block and one
    /// inode, read-only both as a filesystem and as a mount, as MS_RDONLY makes
    /// it. Ubuntu's 5.4 kernels reject `nr_inodes<2`, so runc retries with 2.
    /// Returns the mount descriptor or -errno.
    static func openMaskTmpfs() -> Int32 {
        var code: Int32 = EINVAL
        for inodes in ["1", "2"] {
            let filesystem = unsafe linux_open_filesystem("tmpfs")
            guard filesystem >= 0 else { return -errno }
            defer { _ = close(filesystem) }
            guard unsafe linux_set_filesystem_string(filesystem, "nr_blocks", "1") == 0,
                  unsafe linux_set_filesystem_string(filesystem, "nr_inodes", inodes) == 0,
                  unsafe linux_set_filesystem_flag(filesystem, "ro") == 0,
                  linux_create_filesystem(filesystem) == 0 else {
                code = errno
                continue
            }
            let mount = linux_mount_filesystem(filesystem, 1)
            return mount >= 0 ? mount : -errno
        }
        return -code
    }

    /// Binds the file open at `source` (and, when recursive, the mounts below
    /// it) onto the file open at `target`. Returns 0 or errno.
    static func attachClone(of source: Int32, onto target: Int32, recursive: Bool) -> Int32 {
        let tree = linux_clone_mount(source, recursive ? 1 : 0)
        guard tree >= 0 else { return errno }
        defer { _ = close(tree) }
        guard linux_attach_mount(tree, target) == 0 else { return errno }
        return 0
    }

    static func fileStatus(_ descriptor: Int32) -> stat? {
        var status = stat()
        guard unsafe fstat(descriptor, &status) == 0 else { return nil }
        return status
    }

    static func isType(_ status: stat, _ type: some BinaryInteger) -> Bool {
        status.st_mode & mode_t(LinuxAPI.S_IFMT) == mode_t(type)
    }

    static func isSameFile(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }
}
#endif
