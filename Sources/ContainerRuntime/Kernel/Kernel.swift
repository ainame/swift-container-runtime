#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import SystemPackage

/// The runtime's only gateway to libc and the kernel.
///
/// Files in `Kernel/` import libc (and `LinuxAPI` on Linux); no other runtime
/// file does, which a unit test checks. Kernel API uses Swift types, so C
/// structures stay here. On other platforms Linux-only operations fail with
/// `ENOSYS`, so the runtime still builds and its logic can be tested there.
enum Kernel {}

// libc's ID types, named here so runtime files need not import libc. They are
// the platform's own types, not new ones.
#if canImport(Musl)
typealias pid_t = Musl.pid_t
typealias uid_t = Musl.uid_t
typealias gid_t = Musl.gid_t
#elseif canImport(Glibc)
typealias pid_t = Glibc.pid_t
typealias uid_t = Glibc.uid_t
typealias gid_t = Glibc.gid_t
#elseif canImport(Darwin)
typealias pid_t = Darwin.pid_t
typealias uid_t = Darwin.uid_t
typealias gid_t = Darwin.gid_t
#endif

extension Errno {
    /// The calling thread's `errno`; read it right after the failing call.
    static var current: Errno {
        get { Errno(rawValue: errno) }
        set { errno = newValue.rawValue }
    }
}

extension Kernel {
    enum Process {
        /// getpid(2).
        static var id: pid_t { getpid() }

        static var effectiveUserID: uid_t { geteuid() }
        static var effectiveGroupID: gid_t { getegid() }

        /// The password database's name for `uid`, or nil.
        static func userName(of uid: uid_t) -> String? {
            guard let entry = unsafe getpwuid(uid), let name = unsafe entry.pointee.pw_name else { return nil }
            return unsafe String(cString: name)
        }

        /// Sleeps the calling thread without signals or timers, for short
        /// synchronous backoff.
        static func sleep(for duration: Duration) {
            _ = poll(nil, 0, duration.pollTimeout)
        }
    }
}
