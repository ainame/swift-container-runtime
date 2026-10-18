import ArgumentParser

enum MemorySize {
    /// docker/go-units RAMInBytes uses binary multipliers, accepts decimal
    /// fractions, and truncates fractional bytes. -1 is runc's unlimited value.
    static func bytes(from text: String) throws -> Int64 {
        if text == "-1" { return -1 }
        guard let boundary = text.lastIndex(where: { $0.isASCII && ($0.isNumber || $0 == "." || $0 == " ") }) else {
            throw ValidationError("invalid memory size: \(text)")
        }
        let end = text.index(after: boundary)
        let number = text[boundary] == " " ? text[..<boundary] : text[..<end]
        let suffix = text[end...].lowercased()
        var multiplier: Double = 1
        if !suffix.isEmpty && suffix != "b" {
            guard let first = suffix.first, let power = "kmgtp".firstIndex(of: first) else { throw ValidationError("invalid memory unit: \(suffix)") }
            let tail = suffix.dropFirst()
            guard tail.isEmpty || tail == "b" || tail == "ib" else { throw ValidationError("invalid memory unit: \(suffix)") }
            for _ in 0..."kmgtp".distance(from: "kmgtp".startIndex, to: power) { multiplier *= 1024 }
        }
        guard let value = Double(number), value >= 0, value.isFinite,
              let bytes = Int64(exactly: (value * multiplier).rounded(.towardZero)) else {
            throw ValidationError("memory size is invalid or exceeds Int64: \(text)")
        }
        return bytes
    }
}
