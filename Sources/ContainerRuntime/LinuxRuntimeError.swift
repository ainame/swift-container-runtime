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
extension RuntimeError {
    static func launch(_ stage: LaunchStage, _ code: Int32 = errno, context: String? = nil) -> RuntimeError {
        // Code 0 marks a failure without an errno, such as a refused lookup.
        guard code != 0 else { return RuntimeError(context ?? stage.description) }
        let error = Errno(rawValue: code)
        return RuntimeError("\(context ?? stage.description): \(error) (errno \(code))")
    }
}
#endif
