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
        do {
            try applyAll()
            return nil
        } catch {
            return error
        }
    }

    private func applyAll() throws(LaunchFailure) {
        let root = try at(.resolveReadonlyPath) { () throws(Errno) in try Kernel.File.openPath("/", options: .directory) }
        // A copy of the number for the calls below; `root` owns it until this returns.
        let rootDescriptor = try at(.resolveReadonlyPath) { () throws(Errno) in try root.borrowDescriptor { $0 } }
        for (index, path) in readonly.enumerated() {
            do {
                try Self.makeReadonly(path, root: rootDescriptor)
            } catch var failure {
                failure.detail = Int32(index)
                throw failure
            }
        }
        try mask(root: rootDescriptor)
    }

    /// runc's maskPaths: a non-directory gets the container's /dev/null bound
    /// over it; a directory gets an empty read-only tmpfs. As in runc, the
    /// first directory's tmpfs is bound onto later directories, so they share
    /// one inode, and after a failed bind each later directory gets its own.
    /// Unlike runc, every mask is checked to be what the path now shows, so a
    /// mask hidden from the container (for example one stacked on `/`) fails
    /// setup instead of silently leaving the path unmasked.
    private func mask(root: FileDescriptor) throws(LaunchFailure) {
        guard !masked.isEmpty else { return }
        // runc's verifyDevNull: even when every masked path is missing, the
        // container's /dev/null must be the 1:3 character device.
        let devNull = try at(.openDevNull) { () throws(Errno) in try unsafe Kernel.File.openPath("/dev/null", beneath: root) }
        let devNullDescriptor = try at(.openDevNull) { () throws(Errno) in try devNull.borrowDescriptor { $0 } }
        let devNullStatus = try at(.openDevNull) { () throws(Errno) in try Kernel.File.status(of: devNullDescriptor) }
        guard devNullStatus.isCharacterDevice, devNullStatus.deviceNumber == LinuxDevice.number(1, 3) else {
            throw LaunchFailure(stage: .openDevNull, error: .operationNotSupportedByDevice)  // ENODEV
        }
        let devNullMask = Mask(descriptor: devNullDescriptor, status: devNullStatus)
        var shared = SharedMask()
        for (index, path) in masked.enumerated() {
            do {
                try Self.mask(path, root: root, devNull: devNullMask, shared: &shared)
            } catch var failure {
                failure.detail = Int32(index)
                throw failure
            }
        }
    }

    /// Masks one path, skipped when missing, and verifies the result.
    private static func mask(_ path: String, root: FileDescriptor, devNull: Mask, shared: inout SharedMask) throws(LaunchFailure) {
        guard let target = try at(.resolveMaskedPath, { () throws(Errno) in
            try unsafe Kernel.File.openPathIfPresent(path, beneath: root)
        }) else { return }
        let expected = try at(.maskPath) { () throws(Errno) in
            try target.borrowDescriptor { target throws(Errno) in try attachMask(onto: target, devNull: devNull, shared: &shared) }
        }
        // The path, resolved again, must now show the mask itself.
        let shown = try at(.verifyMaskedPath) { () throws(Errno) in try unsafe Kernel.File.openPath(path, beneath: root) }
        let shownStatus = try? shown.borrowDescriptor { shown throws(Errno) in try Kernel.File.status(of: shown) }
        guard shownStatus?.identity == expected.identity else {
            throw LaunchFailure(stage: .verifyMaskedPath, error: .resourceBusy)
        }
    }

    /// Attaches the right mask onto `target` and returns the file it must show.
    private static func attachMask(onto target: FileDescriptor, devNull: Mask, shared: inout SharedMask) throws(Errno) -> FileStatus {
        guard try Kernel.File.status(of: target).isDirectory else {
            try attachClone(of: devNull.descriptor, onto: target, recursive: false)
            return devNull.status
        }
        if let status = try shared.bind(onto: target) { return status }
        let mask = try openMaskTmpfs()
        let status = try mask.borrowDescriptor { mask throws(Errno) in try Kernel.File.status(of: mask) }
        try mask.borrowDescriptor { mask throws(Errno) in try Kernel.Mount.attach(mask, onto: target) }
        shared.keepIfFirst(mask)
        return status
    }
}

/// An open mask and the file it shows.
private struct Mask {
    let descriptor: FileDescriptor
    let status: FileStatus
}

/// The first directory mask, bound onto later directories as runc does.
private struct SharedMask: ~Copyable {
    private var mount = OwnedFileDescriptor()
    private var exists = false
    private var bindFailed = false

    /// The shared mask's status after binding it onto `target`; nil when there
    /// is none yet, or when a bind fails, after which every later directory
    /// gets its own tmpfs.
    mutating func bind(onto target: FileDescriptor) throws(Errno) -> FileStatus? {
        guard exists, !bindFailed else { return nil }
        let shared = try mount.borrowDescriptor { $0 }
        guard (try? PathControls.attachClone(of: shared, onto: target, recursive: false)) != nil else {
            bindFailed = true
            return nil
        }
        return try Kernel.File.status(of: shared)
    }

    /// Keeps the first directory's tmpfs as the source of later binds.
    mutating func keepIfFirst(_ mask: consuming OwnedFileDescriptor) {
        guard !exists else { return }
        mount = mask
        exists = true
    }
}

/// Runs `body`, attributing its errno to the launch `stage`.
private func at<Result: ~Copyable>(_ stage: LaunchStage, _ body: () throws(Errno) -> Result) throws(LaunchFailure) -> Result {
    do {
        return try body()
    } catch {
        throw LaunchFailure(stage: stage, error: error)
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
    /// below the bind keep their own flags.
    static func makeReadonly(_ path: String, root: FileDescriptor) throws(LaunchFailure) {
        guard let target = try at(.resolveReadonlyPath, { () throws(Errno) in
            try unsafe Kernel.File.openPathIfPresent(path, beneath: root)
        }) else { return }
        let original = try at(.readonlyPath) { () throws(Errno) in
            try target.borrowDescriptor { target throws(Errno) in
                let status = try Kernel.File.status(of: target)
                try attachClone(of: target, onto: target, recursive: true)
                return status
            }
        }
        // A bind shows the same file, so a different one means the path was
        // replaced between the lookups. This does not prove which mount the
        // second lookup reached; see PathControls.apply.
        let reached = try at(.readonlyPath) { () throws(Errno) in try unsafe Kernel.File.openPath(path, beneath: root) }
        try at(.readonlyPath) { () throws(Errno) in
            try reached.borrowDescriptor { reached throws(Errno) in
                guard try Kernel.File.status(of: reached).identity == original.identity else { throw .staleNFSFileHandle }
                try Kernel.Mount.setReadOnly(reached)
            }
        }
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
