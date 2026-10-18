import SystemPackage

extension RuntimeError {
    static func system(_ action: String) -> RuntimeError {
        system(action, Errno.current)
    }
}
extension RuntimeError {
    /// A nil error marks a failure without an errno, such as a refused lookup.
    static func launch(_ stage: LaunchStage, _ error: Errno? = .current, context: String? = nil, detail: Int32 = -1) -> RuntimeError {
        // A container-namespace hook reports runc's message from its packed outcome.
        if stage == .createContainerHook || stage == .startContainerHook {
            let (index, outcome) = HookOutcome.unpack(detail: detail, error: error)
            return RuntimeError(ContainerHooks.failureMessage(stage == .createContainerHook ? .createContainer : .startContainer, index, outcome))
        }
        guard let error else { return RuntimeError(context ?? stage.description) }
        // Docker classifies a failed create by Go's lowercase errno text:
        // "no such file or directory" exits 127, "permission denied" 126.
        // Keep that wording for the workload's execve, as runc reports it.
        let text = stage == .execute ? "\(error)".lowercased() : "\(error)"
        return RuntimeError("\(context ?? stage.description): \(text) (errno \(error.rawValue))")
    }
}
