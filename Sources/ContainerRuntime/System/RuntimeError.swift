
public struct RuntimeError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

extension RuntimeError {
    /// A failed system operation; `error` is usually Kernel's `Errno`.
    static func system(_ action: String, _ error: any Error) -> RuntimeError {
        RuntimeError("\(action): \(error)")
    }
}
