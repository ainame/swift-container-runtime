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

    /// Runs `body`, returning its error instead of throwing it, for code that
    /// reports failures as values (such as child-side launch steps).
    static func failure(_ body: () throws(Errno) -> Void) -> Errno? {
        do {
            try body()
            return nil
        } catch {
            return error
        }
    }
}
