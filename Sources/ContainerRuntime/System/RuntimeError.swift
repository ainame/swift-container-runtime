
/// A failure with a message for people, such as a refused configuration or
/// a failed system call with its errno. Lifecycle conflicts that callers may
/// want to match are ``LifecycleError`` instead.
public struct RuntimeError: Error, CustomStringConvertible, Sendable {
    /// The message, without a program-name prefix.
    public let description: String
    public init(_ description: String) { self.description = description }
}

extension RuntimeError {
    /// A failed system operation; `error` is usually Kernel's `Errno`.
    static func system(_ action: String, _ error: any Error) -> RuntimeError {
        RuntimeError("\(action): \(error)")
    }
}
