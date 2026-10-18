import SystemPackage

/// A host source pinned before any configured mount can hide its original path.
/// Its O_PATH handle never opens a device/FIFO for I/O and is close-on-exec.
final class BindMountSource {
    private let descriptor: OwnedFileDescriptor
    private let isDirectory: Bool

    init(path: String) throws(Errno) {
        descriptor = try Kernel.File.openPath(path)
        isDirectory = try descriptor.borrowDescriptor { descriptor throws(Errno) in try Kernel.File.status(of: descriptor).isDirectory }
    }

    static func pin(_ mounts: [OCIRunPlan.Mount]) throws(LaunchFailure) -> [BindMountSource?] {
        var sources: [BindMountSource?] = []
        for (index, mount) in mounts.enumerated() {
            do {
                sources.append(mount.type == .bind ? try BindMountSource(path: mount.source) : nil)
            } catch {
                throw LaunchFailure(stage: .openMountSource, error: error, detail: Int32(index))
            }
        }
        return sources
    }

    func apply(_ mount: OCIRunPlan.Mount, beneath root: borrowing OwnedFileDescriptor) throws(LaunchFailure) {
        let target = try resolvedTarget(mount, beneath: root)
        do {
            try descriptor.borrowDescriptor { source throws(Errno) in
                let tree = try Kernel.Mount.cloneTree(of: source, recursive: mount.recursiveBind)
                try tree.borrowDescriptor { tree throws(Errno) in
                    // Set only requested attributes before exposing the clone.
                    // rbind,ro changes the top mount; submounts keep their flags.
                    var clear = mount.clearedFlags.bindAttributes
                    if mount.flags.contains(.strictatime) { clear |= 0x70 }
                    try Kernel.Mount.setBindAttributes(tree, set: mount.flags.bindAttributes, clear: clear)
                    if let recursive = mount.recursivePrivate {
                        try Kernel.Mount.makePrivate(tree, recursive: recursive)
                    }
                    try target.borrowDescriptor { target throws(Errno) in try Kernel.Mount.attach(tree, onto: target) }
                }
            }
        } catch {
            throw LaunchFailure(stage: .mount, error: error)
        }
    }

    private func resolvedTarget(_ mount: OCIRunPlan.Mount, beneath root: borrowing OwnedFileDescriptor) throws(LaunchFailure) -> OwnedFileDescriptor {
        do {
            return try root.borrowDescriptor { root throws(Errno) in
                try Self.target(mount.destination, directory: isDirectory, root: root)
            }
        } catch {
            throw LaunchFailure(stage: .resolveMount, error: error)
        }
    }

    /// Resolve existing links with openat2's in-root/no-magic-link policy.
    /// Missing parents are created through pinned, already-resolved parents;
    /// a regular-file source gets a regular-file placeholder at its target.
    /// Dangling symlinks whose referent does not exist fail explicitly.
    private static func target(_ components: [String], directory: Bool, root: FileDescriptor) throws(Errno) -> OwnedFileDescriptor {
        var path = ""
        for (index, name) in components.enumerated() {
            let parentPath = path.isEmpty ? "/" : path
            path += "/" + name
            let last = index == components.count - 1
            let needsDirectory = !last || directory
            let opened = try openOrCreate(path, name: name, parentPath: parentPath, directory: needsDirectory, root: root)
            if last {
                let actual = try opened.borrowDescriptor { descriptor throws(Errno) in try Kernel.File.status(of: descriptor).isDirectory }
                guard actual == directory else { throw directory ? .notDirectory : .isDirectory }
                return opened
            }
        }
        throw .invalidArgument // plans reject mounting over the root itself
    }
    private static func openOrCreate(_ path: String, name: String, parentPath: String, directory: Bool, root: FileDescriptor) throws(Errno) -> OwnedFileDescriptor {
        do {
            return try Kernel.File.openPathInRoot(path, beneath: root, options: directory ? .directory : [])
        } catch .noSuchFileOrDirectory {
        }
        let parent = try Kernel.File.openPathInRoot(parentPath, beneath: root, options: .directory)
        try parent.borrowDescriptor { parent throws(Errno) in
            do throws(Errno) {
                if directory {
                    try Kernel.File.makeDirectory(name, in: parent, permissions: FilePermissions(rawValue: 0o755))
                } else {
                    var file = try Kernel.File.open(name, in: parent, .writeOnly,
                        options: [.create, .exclusiveCreate, .noFollow], permissions: FilePermissions(rawValue: 0o644))
                    try? file.close()
                }
            } catch .fileExists {
                // Reopen in-root; never follow an unconfined final link when
                // creating a placeholder (including a dangling symlink).
            }
        }
        return try Kernel.File.openPathInRoot(path, beneath: root, options: directory ? .directory : [])
    }

}

private extension OCIRunPlan.MountFlags {
    var bindAttributes: UInt64 {
        var value: UInt64 = 0
        if contains(.readonly) { value |= 1 }
        if contains(.nosuid) { value |= 2 }
        if contains(.nodev) { value |= 4 }
        if contains(.noexec) { value |= 8 }
        if contains(.strictatime) { value |= 0x20 }
        return value
    }
}
