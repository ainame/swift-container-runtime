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
    /// Linux security module availability and the calling thread's procfs
    /// attributes (`/proc/thread-self/attr/*`), which stage a context for
    /// the next execve or for keys the thread creates.
    enum SecurityModule {
        /// The attribute files this runtime writes.
        enum Attribute {
            /// AppArmor's own exec attribute, or the shared `attr/exec` on
            /// kernels without the per-module directory.
            case appArmorExec
            /// The SELinux exec context.
            case selinuxExec
            /// The SELinux context of keys, and keyrings, created afterwards.
            case selinuxKeyCreation
        }

        /// runc's check: securityfs shows AppArmor and the module parameter
        /// says it is enabled. Called by the supervisor before fork.
        static var isAppArmorEnabled: Bool {
            guard (try? Kernel.File.status(atPath: "/sys/kernel/security/apparmor")) != nil else { return false }
            return (try? readFirstBytes("/sys/module/apparmor/parameters/enabled")).map { $0.first == UInt8(ascii: "Y") } ?? false
        }

        /// go-selinux's check: selinuxfs is mounted at /sys/fs/selinux and the
        /// process context is not the "kernel" context of a host without a
        /// loaded policy. Called by the supervisor before fork.
        static var isSELinuxEnabled: Bool {
            #if os(Linux)
            var status = statfs()
            // SELINUX_MAGIC from <linux/magic.h>.
            guard unsafe statfs("/sys/fs/selinux", &status) == 0,
                  UInt64(truncatingIfNeeded: status.f_type) == 0xf97c_ff8c else { return false }
            guard let context = try? readFirstBytes("/proc/self/attr/current") else { return false }
            let trimmed = context.prefix { $0 != 0 && $0 != UInt8(ascii: "\n") }
            return !trimmed.isEmpty && !trimmed.elementsEqual("kernel".utf8)
            #else
            return false
            #endif
        }

        /// Writes `bytes` to the calling thread's attribute in one write(2).
        /// The file must be on procfs, so a container root without a /proc
        /// mount cannot silently swallow the label in an ordinary file. Used
        /// between fork and exec: the paths are literals and nothing allocates.
        static func write(_ attribute: Attribute, _ bytes: [UInt8]) throws(Errno) {
            #if os(Linux)
            let descriptor: Int32
            switch attribute {
            case .appArmorExec:
                let modern = unsafe openat(AT_FDCWD, "/proc/thread-self/attr/apparmor/exec", O_WRONLY | O_CLOEXEC)
                descriptor = modern >= 0 || Errno.current != .noSuchFileOrDirectory
                    ? modern : unsafe openat(AT_FDCWD, "/proc/thread-self/attr/exec", O_WRONLY | O_CLOEXEC)
            case .selinuxExec:
                descriptor = unsafe openat(AT_FDCWD, "/proc/thread-self/attr/exec", O_WRONLY | O_CLOEXEC)
            case .selinuxKeyCreation:
                descriptor = unsafe openat(AT_FDCWD, "/proc/thread-self/attr/keycreate", O_WRONLY | O_CLOEXEC)
            }
            guard descriptor >= 0 else { throw .current }
            defer { _ = close(descriptor) }
            var status = statfs()
            guard unsafe fstatfs(descriptor, &status) == 0 else { throw .current }
            // PROC_SUPER_MAGIC from <linux/magic.h>.
            guard UInt64(truncatingIfNeeded: status.f_type) == 0x9fa0 else { throw .notSupported }
            guard try Kernel.File.write(FileDescriptor(rawValue: descriptor), bytes.span.bytes) == bytes.count else { throw .ioError }
            #else
            throw .noFunction
            #endif
        }

        /// Up to 256 bytes of a small kernel status file.
        private static func readFirstBytes(_ path: String) throws(Errno) -> [UInt8] {
            let file = try Kernel.File.open(path, .readOnly)
            return try file.borrowDescriptor { descriptor throws(Errno) in try Kernel.File.read(descriptor, upTo: 256) }
        }
    }
}
