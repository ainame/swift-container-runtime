#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

extension Kernel {
    /// The libm functions the runtime needs; the standard library has none.
    enum Math {
        static func log2(_ value: Double) -> Double { libmLog2(value) }
        static func power(_ base: Double, _ exponent: Double) -> Double { libmPow(base, exponent) }
    }
}

// At file scope these names reach libm rather than the methods above.
private func libmLog2(_ value: Double) -> Double { log2(value) }
private func libmPow(_ base: Double, _ exponent: Double) -> Double { pow(base, exponent) }
