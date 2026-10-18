#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import LinuxAPI
import SystemPackage

extension RuntimeError {
    static func system(_ action: String, _ code: Int32 = errno) -> RuntimeError {
        RuntimeError("\(action): \(Errno(rawValue: code))")
    }
}
#endif
