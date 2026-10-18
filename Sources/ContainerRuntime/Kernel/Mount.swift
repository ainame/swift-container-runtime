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
import SystemPackage

/// mount(2) flags, with Linux's stable values so they are spelled the same on
/// every platform.
struct MountFlags: OptionSet, Sendable {
    let rawValue: UInt

    static let readOnly = MountFlags(rawValue: 1)
    static let noSetUserID = MountFlags(rawValue: 2)
    static let noDevices = MountFlags(rawValue: 4)
    static let noExecute = MountFlags(rawValue: 8)
    static let remount = MountFlags(rawValue: 32)
    static let noSymbolicLinkFollow = MountFlags(rawValue: 256)
    static let bind = MountFlags(rawValue: 4096)
    static let move = MountFlags(rawValue: 8192)
    static let recursive = MountFlags(rawValue: 16384)
    /// MS_PRIVATE: no mount propagation to or from peers.
    static let privatePropagation = MountFlags(rawValue: 1 << 18)
    static let strictAccessTime = MountFlags(rawValue: 1 << 24)
}

extension Kernel {
    /// Mounts, the root switch, and the descriptor-based mount API (Linux
    /// 5.2+; mount_setattr 5.12+). Paths are C strings so that code between
    /// fork and exec can pass the buffers it already holds.
    enum Mount {
        /// mount(2).
        static func mount(
            source: UnsafePointer<CChar>?, target: UnsafePointer<CChar>, type: UnsafePointer<CChar>?,
            flags: MountFlags, data: UnsafeRawPointer? = nil
        ) throws(Errno) {
            #if os(Linux)
            guard unsafe LinuxAPI.mount(source, target, type, flags.rawValue, data) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        /// umount2(MNT_DETACH).
        static func unmountDetached(_ target: UnsafePointer<CChar>) throws(Errno) {
            #if os(Linux)
            guard unsafe umount2(target, Int32(MNT_DETACH)) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        /// pivot_root(2).
        static func pivotRoot(_ newRoot: UnsafePointer<CChar>, _ putOld: UnsafePointer<CChar>) throws(Errno) {
            #if os(Linux)
            guard unsafe linux_pivot_root(newRoot, putOld) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        /// statvfs(3)'s `f_flag` for the filesystem holding `path`.
        static func statusFlags(ofPath path: UnsafePointer<CChar>) throws(Errno) -> UInt {
            var status = statvfs()
            guard unsafe statvfs(path, &status) == 0 else { throw .current }
            return UInt(status.f_flag)
        }

        /// open_tree(OPEN_TREE_CLONE): a detached bind of the file open at
        /// `source`, with every mount below it when `recursive`.
        static func cloneTree(of source: FileDescriptor, recursive: Bool) throws(Errno) -> OwnedFileDescriptor {
            #if os(Linux)
            try owned(linux_clone_mount(source.rawValue, recursive ? 1 : 0))
            #else
            throw .noFunction
            #endif
        }

        /// move_mount(2) of the detached mount at `mount` onto the file open at `target`.
        static func attach(_ mount: FileDescriptor, onto target: FileDescriptor) throws(Errno) {
            #if os(Linux)
            guard linux_attach_mount(mount.rawValue, target.rawValue) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        /// mount_setattr(MOUNT_ATTR_RDONLY) on the mount whose root is open at `mount`.
        static func setReadOnly(_ mount: FileDescriptor) throws(Errno) {
            #if os(Linux)
            guard linux_set_mount_readonly(mount.rawValue) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        /// mount_setattr(2): sets and clears only the per-mount flags among
        /// `set` and `clear` (read-only, nosuid, nodev, noexec, strictatime),
        /// keeping inherited flags and every submount's attributes.
        static func changeFlags(_ mount: FileDescriptor, set: MountFlags, clear: MountFlags) throws(Errno) {
            #if os(Linux)
            guard !set.isEmpty || !clear.isEmpty else { return }
            guard linux_change_mount_flags(mount.rawValue, set.rawValue, clear.rawValue) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        /// mount_setattr(MS_PRIVATE) on the mount open at `mount`, and on
        /// every mount below it when `recursive`.
        static func makePrivate(_ mount: FileDescriptor, recursive: Bool) throws(Errno) {
            #if os(Linux)
            guard linux_make_mount_private(mount.rawValue, recursive ? 1 : 0) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        /// fsopen(2): a filesystem context for `type`.
        static func openFilesystem(_ type: UnsafePointer<CChar>) throws(Errno) -> OwnedFileDescriptor {
            #if os(Linux)
            try owned(unsafe linux_open_filesystem(type))
            #else
            throw .noFunction
            #endif
        }

        /// fsconfig(FSCONFIG_SET_STRING).
        static func setOption(_ context: FileDescriptor, _ key: UnsafePointer<CChar>, _ value: UnsafePointer<CChar>) throws(Errno) {
            #if os(Linux)
            guard unsafe linux_set_filesystem_string(context.rawValue, key, value) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        /// fsconfig(FSCONFIG_SET_FLAG).
        static func setFlag(_ context: FileDescriptor, _ key: UnsafePointer<CChar>) throws(Errno) {
            #if os(Linux)
            guard unsafe linux_set_filesystem_flag(context.rawValue, key) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        /// fsconfig(FSCONFIG_CMD_CREATE).
        static func createFilesystem(_ context: FileDescriptor) throws(Errno) {
            #if os(Linux)
            guard linux_create_filesystem(context.rawValue) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        /// fsmount(2): a detached mount of the created filesystem.
        static func mountFilesystem(_ context: FileDescriptor, readOnly: Bool) throws(Errno) -> OwnedFileDescriptor {
            #if os(Linux)
            try owned(linux_mount_filesystem(context.rawValue, readOnly ? 1 : 0))
            #else
            throw .noFunction
            #endif
        }

        private static func owned(_ raw: Int32) throws(Errno) -> OwnedFileDescriptor {
            guard raw >= 0 else { throw .current }
            return OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
        }
    }
}
