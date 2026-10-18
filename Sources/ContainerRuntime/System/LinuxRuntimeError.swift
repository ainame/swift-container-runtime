import SystemPackage

extension RuntimeError {
    static func system(_ action: String) -> RuntimeError {
        system(action, Errno.current)
    }
}
extension RuntimeError {
    /// A nil error marks a failure without an errno, such as a refused lookup.
    static func launch(_ stage: LaunchStage, _ error: Errno? = .current, context: String? = nil) -> RuntimeError {
        guard let error else { return RuntimeError(context ?? stage.description) }
        return RuntimeError("\(context ?? stage.description): \(error) (errno \(error.rawValue))")
    }
}
