import SystemPackage

/// A bind source pinned by its host path before any configured mount can hide
/// it. The O_PATH handle never opens a device or FIFO for I/O and is
/// close-on-exec. The init creates it between fork and exec, from the
/// prepared launch strings.
final class BindMountSource {
    private let descriptor: OwnedFileDescriptor
    private let isDirectory: Bool

    @unsafe
    init(path: UnsafePointer<CChar>) throws(Errno) {
        descriptor = try unsafe Kernel.File.openPath(path)
        isDirectory = try descriptor.borrowDescriptor { descriptor throws(Errno) in try Kernel.File.status(of: descriptor).isDirectory }
    }

    /// Clones the source (with every mount below it for `rbind`), changes
    /// only the requested flags and propagation on the detached clone, then
    /// attaches it on the destination resolved beneath `root`.
    /// Returns nil or the failure.
    @unsafe
    func attach(
        _ mount: OCIRunPlan.Mount,
        components: UnsafePointer<UnsafeMutablePointer<CChar>?>, prefixes: UnsafePointer<UnsafeMutablePointer<CChar>?>,
        beneath root: borrowing OwnedFileDescriptor
    ) -> LaunchFailure? {
        var target = OwnedFileDescriptor()
        do {
            target = try root.borrowDescriptor { root throws(Errno) in
                try unsafe Self.resolve(components, prefixes, isDirectory: isDirectory, root: root, parent: root)
            }
        } catch {
            return LaunchFailure(stage: .resolveMount, error: error)
        }
        do {
            try descriptor.borrowDescriptor { source throws(Errno) in
                let tree = try Kernel.Mount.cloneTree(of: source, recursive: mount.recursiveBind)
                try tree.borrowDescriptor { tree throws(Errno) in
                    // Before the clone is visible. As in runc, rbind,ro changes
                    // the top mount only; submounts keep their own flags.
                    try Kernel.Mount.changeFlags(tree, set: mount.flags.kernelFlags, clear: mount.clearedFlags.kernelFlags)
                    if let propagation = mount.propagation {
                        try Kernel.Mount.makePrivate(tree, recursive: propagation == .recursivePrivate)
                    }
                    try target.borrowDescriptor { target throws(Errno) in try Kernel.Mount.attach(tree, onto: target) }
                }
            }
        } catch {
            return LaunchFailure(stage: .mount, error: error)
        }
        return nil
    }

    /// Resolves the destination one absolute prefix at a time with openat2's
    /// in-root, no-magic-link policy, so existing symbolic links (such as an
    /// image's /etc/resolv.conf) stay below `root`. A missing component is
    /// created in its resolved parent: a directory, or an empty regular file
    /// for the last component of a file source. The final entry must match
    /// the source's kind.
    @unsafe
    private static func resolve(
        _ components: UnsafePointer<UnsafeMutablePointer<CChar>?>, _ prefixes: UnsafePointer<UnsafeMutablePointer<CChar>?>,
        isDirectory: Bool, root: FileDescriptor, parent: FileDescriptor
    ) throws(Errno) -> OwnedFileDescriptor {
        // Plans reject an empty destination, so there is always a component.
        let last = unsafe components[1] == nil
        let opened = try unsafe openOrCreate(
            prefixes[0]!, name: components[0]!, in: parent, directory: !last || isDirectory, root: root)
        guard last else {
            return try opened.borrowDescriptor { opened throws(Errno) in
                try unsafe resolve(components + 1, prefixes + 1, isDirectory: isDirectory, root: root, parent: opened)
            }
        }
        let openedIsDirectory = try opened.borrowDescriptor { descriptor throws(Errno) in
            try Kernel.File.status(of: descriptor).isDirectory
        }
        guard openedIsDirectory == isDirectory else { throw isDirectory ? .notDirectory : .isDirectory }
        return opened
    }

    /// The entry at `path` beneath `root`, created first as `name` in
    /// `parent` when it is missing. Creation never follows a final symbolic
    /// link: a dangling one stays missing and the reopen fails with ENOENT.
    @unsafe
    private static func openOrCreate(
        _ path: UnsafePointer<CChar>, name: UnsafePointer<CChar>, in parent: FileDescriptor, directory: Bool, root: FileDescriptor
    ) throws(Errno) -> OwnedFileDescriptor {
        let options: FileDescriptor.OpenOptions = directory ? .directory : []
        do {
            return try unsafe Kernel.File.openPath(path, beneath: root, options: options)
        } catch .noSuchFileOrDirectory {
        }
        do {
            if directory {
                try unsafe Kernel.File.makeDirectory(name, in: parent, permissions: FilePermissions(rawValue: 0o755))
            } else {
                try unsafe Kernel.File.makeEmptyFile(name, in: parent, permissions: FilePermissions(rawValue: 0o644))
            }
        } catch .fileExists {
        }
        return try unsafe Kernel.File.openPath(path, beneath: root, options: options)
    }
}
