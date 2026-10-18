#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import LinuxAPI
import SystemPackage

extension RFC3339 {
    /// The current UTC time in RFC 3339 form.
    static func now() -> String {
        var now = timespec()
        _ = unsafe clock_gettime(CLOCK_REALTIME, &now)
        return RFC3339.format(seconds: Int64(now.tv_sec), nanoseconds: Int64(now.tv_nsec))
    }
}
#endif
