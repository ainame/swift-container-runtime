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

import SystemPackage

/// A `LaunchFailure`'s detail here is the index into `readonly` or `masked`,
/// or -1 for the shared setup.
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
    func apply() -> LaunchFailure? {
        var root = OwnedFileDescriptor()
        if let error = Errno.failure({ () throws(Errno) in root = try Kernel.File.openPath("/", options: .directory) }) {
            return LaunchFailure(stage: .resolveReadonlyPath, error: error)
        }
        let closed = LaunchFailure(stage: .resolveReadonlyPath, error: .badFileDescriptor)
        return root.failure(in: { root in
            for (index, path) in readonly.enumerated() {
                if var failure = Self.makeReadonly(path, root: root) {
                    failure.detail = Int32(index)
                    return failure
                }
            }
            return mask(root: root)
        }, whenClosed: closed)
    }

    /// runc's maskPaths: a non-directory gets the container's /dev/null bound
    /// over it; a directory gets an empty read-only tmpfs. As in runc, the
    /// first directory's tmpfs is bound onto later directories, so they share
    /// one inode, and after a failed bind each later directory gets its own.
    /// Unlike runc, every mask is checked to be what the path now shows, so a
    /// mask hidden from the container (for example one stacked on `/`) fails
    /// setup instead of silently leaving the path unmasked.
    private func mask(root: FileDescriptor) -> LaunchFailure? {
        guard !masked.isEmpty else { return nil }
        // runc's verifyDevNull: even when every masked path is missing, the
        // container's /dev/null must be the 1:3 character device.
        var devNull = OwnedFileDescriptor()
        if let error = Errno.failure({ () throws(Errno) in devNull = try unsafe Kernel.File.openPath("/dev/null", beneath: root) }) {
            return LaunchFailure(stage: .openDevNull, error: error)
        }
        let closed = LaunchFailure(stage: .openDevNull, error: .badFileDescriptor)
        return devNull.failure(in: { devNull in
            var status: FileStatus? = nil
            if let error = Errno.failure({ () throws(Errno) in status = try Kernel.File.status(of: devNull) }) {
                return LaunchFailure(stage: .openDevNull, error: error)
            }
            guard let devNullStatus = status else { return LaunchFailure(stage: .openDevNull, error: .ioError) }
            guard devNullStatus.isCharacterDevice, devNullStatus.deviceNumber == LinuxDevice.number(1, 3) else {
                return LaunchFailure(stage: .openDevNull, error: .operationNotSupportedByDevice)  // ENODEV
            }
            return maskEach(root: root, devNull: devNull, devNullStatus: devNullStatus)
        }, whenClosed: closed)
    }

    /// Masks each path in order; see `mask(root:)`.
    private func maskEach(root: FileDescriptor, devNull: FileDescriptor, devNullStatus: FileStatus) -> LaunchFailure? {
        // The first directory mask's mount, kept as the source of later
        // directory binds; closed when this returns.
        var shared = OwnedFileDescriptor()
        var hasShared = false
        var sharedBindFailed = false
        for (index, path) in masked.enumerated() {
            func failure(_ stage: LaunchStage, _ error: Errno) -> LaunchFailure {
                LaunchFailure(stage: stage, error: error, detail: Int32(index))
            }
            var target = OwnedFileDescriptor()
            if let error = Errno.failure({ () throws(Errno) in target = try unsafe Kernel.File.openPath(path, beneath: root) }) {
                if error == .noSuchFileOrDirectory { continue }
                return failure(.resolveMaskedPath, error)
            }

            // Attach the mask and remember the file it must show.
            var expected: FileStatus? = nil
            let attachError: Errno? = target.failure(in: { target in
                Errno.failure { () throws(Errno) in
                    let status = try Kernel.File.status(of: target)
                    if !status.isDirectory {
                        try Self.attachClone(of: devNull, onto: target, recursive: false)
                        expected = devNullStatus
                        return
                    }
                    if hasShared, !sharedBindFailed {
                        // nil when the bind failed; a failed fstat after a bind fails setup.
                        let sharedStatus = try shared.borrowDescriptor { shared throws(Errno) -> FileStatus? in
                            guard (try? Self.attachClone(of: shared, onto: target, recursive: false)) != nil else { return nil }
                            return try Kernel.File.status(of: shared)
                        }
                        if let sharedStatus {
                            expected = sharedStatus
                            return
                        }
                        // A shared bind failing makes every later directory use its own tmpfs.
                        sharedBindFailed = true
                    }
                    let mask = try Self.openMaskTmpfs()
                    let maskStatus = try mask.borrowDescriptor { mask throws(Errno) in try Kernel.File.status(of: mask) }
                    try mask.borrowDescriptor { mask throws(Errno) in try Kernel.Mount.attach(mask, onto: target) }
                    expected = maskStatus
                    if !hasShared && !sharedBindFailed {
                        shared = mask
                        hasShared = true
                    }
                }
            })
            if let attachError { return failure(.maskPath, attachError) }

            // The path, resolved again, must now show the mask itself.
            var shown = OwnedFileDescriptor()
            if let error = Errno.failure({ () throws(Errno) in shown = try unsafe Kernel.File.openPath(path, beneath: root) }) {
                return failure(.verifyMaskedPath, error)
            }
            let shownStatus: FileStatus? = shown.failure(in: { try? Kernel.File.status(of: $0) }, whenClosed: nil) ?? nil
            guard let shownStatus, let expected, shownStatus.identity == expected.identity else {
                return failure(.verifyMaskedPath, .resourceBusy)
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
    /// below the bind keep their own flags. Returns nil or the failure.
    static func makeReadonly(_ path: String, root: FileDescriptor) -> LaunchFailure? {
        var target = OwnedFileDescriptor()
        if let error = Errno.failure({ () throws(Errno) in target = try unsafe Kernel.File.openPath(path, beneath: root) }) {
            return error == .noSuchFileOrDirectory ? nil : LaunchFailure(stage: .resolveReadonlyPath, error: error)
        }
        var original: FileStatus? = nil
        let bindError = target.failure(in: { target in
            Errno.failure { () throws(Errno) in
                original = try Kernel.File.status(of: target)
                try attachClone(of: target, onto: target, recursive: true)
            }
        })
        if let bindError { return LaunchFailure(stage: .readonlyPath, error: bindError) }

        // A bind shows the same file, so a different one means the path was
        // replaced between the lookups. This does not prove which mount the
        // second lookup reached; see PathControls.apply.
        var reached = OwnedFileDescriptor()
        if let error = Errno.failure({ () throws(Errno) in reached = try unsafe Kernel.File.openPath(path, beneath: root) }) {
            return LaunchFailure(stage: .readonlyPath, error: error)
        }
        let remountError = reached.failure(in: { reached in
            Errno.failure { () throws(Errno) in
                guard try Kernel.File.status(of: reached).identity == original?.identity else { throw .staleNFSFileHandle }
                try Kernel.Mount.setReadOnly(reached)
            }
        })
        return remountError.map { LaunchFailure(stage: .readonlyPath, error: $0) }
    }

    /// runc's maskDir as a detached mount: an empty tmpfs with one block and one
    /// inode, read-only both as a filesystem and as a mount, as MS_RDONLY makes
    /// it. Ubuntu's 5.4 kernels reject `nr_inodes<2`, so runc retries with 2.
    static func openMaskTmpfs() throws(Errno) -> OwnedFileDescriptor {
        var error = Errno.invalidArgument
        for inodes in ["1", "2"] {
            let context = try unsafe Kernel.Mount.openFilesystem("tmpfs")
            do {
                try context.borrowDescriptor { context throws(Errno) in
                    try unsafe Kernel.Mount.setOption(context, "nr_blocks", "1")
                    try unsafe Kernel.Mount.setOption(context, "nr_inodes", inodes)
                    try unsafe Kernel.Mount.setFlag(context, "ro")
                    try Kernel.Mount.createFilesystem(context)
                }
            } catch let failure {
                error = failure
                continue
            }
            return try context.borrowDescriptor { context throws(Errno) in try Kernel.Mount.mountFilesystem(context, readOnly: true) }
        }
        throw error
    }

    /// Binds the file open at `source` (and, when recursive, the mounts below
    /// it) onto the file open at `target`.
    static func attachClone(of source: FileDescriptor, onto target: FileDescriptor, recursive: Bool) throws(Errno) {
        let tree = try Kernel.Mount.cloneTree(of: source, recursive: recursive)
        try tree.borrowDescriptor { tree throws(Errno) in try Kernel.Mount.attach(tree, onto: target) }
    }
}
