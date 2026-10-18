#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif

/// Linux device identifier encoding, shared by rootfs setup and path masking.
enum LinuxDevice {
    /// Linux's dev_t encoding (the glibc/musl `makedev` macro is not imported).
    static func number(_ major: UInt32, _ minor: UInt32) -> dev_t {
        let major = UInt64(major), minor = UInt64(minor)
        let value = ((major & 0xffff_f000) << 32) | ((major & 0xfff) << 8) | ((minor & 0xffff_ff00) << 12) | (minor & 0xff)
        return dev_t(value)
    }
}
#endif
