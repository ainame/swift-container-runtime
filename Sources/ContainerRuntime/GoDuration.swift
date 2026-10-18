public enum GoDuration {
    /// Go's time.ParseDuration, which runc uses for `events --interval`.
    /// Returns nanoseconds; the error text matches Go's.
    public static func nanoseconds(from text: String) throws -> Int64 {
        let invalid = RuntimeError("time: invalid duration \(GoText.quote(text))")
        var bytes = Substring(text).utf8[...]
        var negative = false
        if let first = bytes.first, first == UInt8(ascii: "-") || first == UInt8(ascii: "+") {
            negative = first == UInt8(ascii: "-")
            bytes = bytes.dropFirst()
        }
        if bytes.elementsEqual("0".utf8) { return 0 }
        guard !bytes.isEmpty else { throw invalid }

        let limit: UInt64 = 1 << 63
        let units: [String: UInt64] = [
            "ns": 1, "us": 1_000, "\u{00B5}s": 1_000, "\u{03BC}s": 1_000,
            "ms": 1_000_000, "s": 1_000_000_000, "m": 60_000_000_000, "h": 3_600_000_000_000,
        ]
        func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }
        let dot = UInt8(ascii: ".")

        var total: UInt64 = 0
        while let first = bytes.first {
            guard first == dot || isDigit(first) else { throw invalid }

            // The integer part; overflow is an error, as in Go's leadingInt.
            var value: UInt64 = 0
            var sawInteger = false
            while let byte = bytes.first, isDigit(byte) {
                guard value <= limit / 10 else { throw invalid }
                value = value * 10 + UInt64(byte - UInt8(ascii: "0"))
                guard value <= limit else { throw invalid }
                bytes = bytes.dropFirst()
                sawInteger = true
            }

            // The fraction stops accumulating once it would overflow, as in
            // Go's leadingFraction.
            var fraction: UInt64 = 0
            var scale = 1.0
            var sawFraction = false
            if bytes.first == dot {
                bytes = bytes.dropFirst()
                var overflowed = false
                while let byte = bytes.first, isDigit(byte) {
                    bytes = bytes.dropFirst()
                    sawFraction = true
                    if overflowed { continue }
                    guard fraction <= (limit - 1) / 10 else { overflowed = true; continue }
                    let next = fraction * 10 + UInt64(byte - UInt8(ascii: "0"))
                    guard next <= limit else { overflowed = true; continue }
                    fraction = next
                    scale *= 10
                }
            }
            guard sawInteger || sawFraction else { throw invalid }

            // The unit runs to the next number.
            let unitBytes = bytes.prefix { $0 != dot && !isDigit($0) }
            bytes = bytes.dropFirst(unitBytes.count)
            let unitName = String(decoding: unitBytes, as: UTF8.self)
            guard !unitBytes.isEmpty else { throw RuntimeError("time: missing unit in duration \(GoText.quote(text))") }
            guard let unit = units[unitName] else {
                throw RuntimeError("time: unknown unit \(GoText.quote(unitName)) in duration \(GoText.quote(text))")
            }

            guard value <= limit / unit else { throw invalid }
            value *= unit
            // value is at most 2^63 and the fraction adds less than one unit,
            // so this sum cannot wrap.
            if fraction > 0 {
                value += UInt64(Double(fraction) * (Double(unit) / scale))
                guard value <= limit else { throw invalid }
            }
            // Go's uint64 sum wraps here, so "-9223372036854775808ns9223372036854775808ns"
            // parses as 0 there; a sum beyond 2^63 is rejected instead of wrapping.
            guard value <= limit - total else { throw invalid }
            total += value
        }
        if negative { return total == limit ? Int64.min : -Int64(total) }
        guard total <= UInt64(Int64.max) else { throw invalid }
        return Int64(total)
    }


}

/// Compatibility entry point; new callers can use `GoDuration.nanoseconds(from:)`.
public func parseGoDuration(_ text: String) throws -> Int64 {
    try GoDuration.nanoseconds(from: text)
}
