#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
import SystemPackage

public struct RuntimeError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

extension Errno {
    /// The calling thread's `errno`; read it before any call that may change it.
    static var current: Errno { Errno(rawValue: errno) }
}
