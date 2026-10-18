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

extension Kernel {
    /// Pseudoterminal operations for the init or exec process between fork
    /// and exec, inside the container root. Paths are literals; nothing
    /// allocates.
    enum Terminal {
        /// A new pseudoterminal master from the container's devpts instance.
        /// `/dev/pts/ptmx` is first pinned without opening it and must be the
        /// 5:2 character device on devpts, so an image's device node there is
        /// never opened; the read-write reopen must be that same file. The
        /// master never becomes this process's controlling terminal.
        static func openMaster() throws(Errno) -> OwnedFileDescriptor {
            #if os(Linux)
            let pinned = try Kernel.File.openPath("/dev/pts/ptmx", options: .noFollow)
            let expected = try pinned.borrowDescriptor { descriptor throws(Errno) in
                try verifiedPtmx(descriptor)
            }
            let raw = unsafe openat(AT_FDCWD, "/dev/pts/ptmx", O_RDWR | O_NOCTTY | O_NOFOLLOW | O_CLOEXEC)
            guard raw >= 0 else { throw .current }
            let master = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
            let actual = try master.borrowDescriptor { descriptor throws(Errno) in try verifiedPtmx(descriptor) }
            // A replaced entry between the two opens is refused.
            guard actual == expected else { throw .staleNFSFileHandle }
            return master
            #else
            throw .noFunction
            #endif
        }

        /// Unlocks the master and opens its peer through TIOCGPTPEER, read-write,
        /// close-on-exec and without making it the controlling terminal.
        static func openPeer(of master: FileDescriptor) throws(Errno) -> OwnedFileDescriptor {
            #if os(Linux)
            guard linux_unlock_pty(master.rawValue) == 0 else { throw .current }
            let raw = linux_open_pty_peer(master.rawValue)
            guard raw >= 0 else { throw .current }
            return OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
            #else
            throw .noFunction
            #endif
        }

        /// TIOCSWINSZ: the terminal's initial size in character cells.
        static func setWindowSize(_ terminal: FileDescriptor, rows: UInt16, columns: UInt16) throws(Errno) {
            #if os(Linux)
            guard linux_set_window_size(terminal.rawValue, rows, columns) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        /// dup3(2) of `terminal` onto standard input, output and error, then
        /// TIOCSCTTY: the terminal becomes the controlling terminal of this
        /// session leader's session.
        static func becomeStdio(_ terminal: FileDescriptor) throws(Errno) {
            #if os(Linux)
            for target: Int32 in 0...2 where terminal.rawValue != target {
                guard dup3(terminal.rawValue, target, 0) >= 0 else { throw .current }
            }
            guard linux_set_controlling_terminal(0) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        #if os(Linux)
        /// The file's identity when it is the devpts ptmx device; ENODEV otherwise.
        private static func verifiedPtmx(_ descriptor: FileDescriptor) throws(Errno) -> FileIdentity {
            var filesystem = statfs()
            guard unsafe fstatfs(descriptor.rawValue, &filesystem) == 0 else { throw .current }
            let status = try Kernel.File.status(of: descriptor)
            // DEVPTS_SUPER_MAGIC from <linux/magic.h>; ptmx is character device 5:2.
            guard UInt64(truncatingIfNeeded: filesystem.f_type) == 0x1cd1,
                  status.isCharacterDevice, status.deviceNumber == LinuxDevice.number(5, 2) else {
                throw .operationNotSupportedByDevice
            }
            return status.identity
        }
        #endif
    }
}
