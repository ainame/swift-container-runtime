/// Why a duration text was refused.
public struct DurationParseError: Error, CustomStringConvertible, Sendable {
    public let text: String
    public let reason: String

    public var description: String { "invalid duration \(text.debugDescription): \(reason)" }
}

extension Duration {
    /// Units accepted after each number, in nanoseconds.
    private static let units: [Substring: Int128] = [
        "ns": 1, "us": 1_000, "\u{00B5}s": 1_000, "\u{03BC}s": 1_000,
        "ms": 1_000_000, "s": 1_000_000_000, "m": 60_000_000_000, "h": 3_600_000_000_000,
    ]

    /// Parses an optionally signed sequence of decimal numbers, each with a
    /// unit, such as `5s`, `300ms`, `1.5h` or `1m30s`. Units are `h`, `m`,
    /// `s`, `ms`, `us` (or `µs`) and `ns`; a bare `0` needs none. Fractions
    /// finer than a nanosecond are truncated, and the total must fit in
    /// `Int64` nanoseconds.
    public init(parsing text: String) throws(DurationParseError) {
        func refuse(_ reason: String) -> DurationParseError { DurationParseError(text: text, reason: reason) }
        func isNumeric(_ character: Character) -> Bool { character == "." || ("0"..."9").contains(character) }

        var rest = Substring(text)
        let negative = rest.first == "-"
        if rest.first == "-" || rest.first == "+" { rest.removeFirst() }
        if rest == "0" {
            self = .zero
            return
        }
        guard !rest.isEmpty else { throw refuse("expected a number") }

        // Sum the components in a wider type, checking the range as it grows.
        let limit = Int128(Int64.max) + 1
        var total: Int128 = 0
        while !rest.isEmpty {
            let number = rest.prefix(while: isNumeric)
            rest = rest.dropFirst(number.count)
            let unitName = rest.prefix { !isNumeric($0) }
            rest = rest.dropFirst(unitName.count)

            let parts = number.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count <= 2, parts.contains(where: { !$0.isEmpty }) else { throw refuse("expected a number") }
            guard !unitName.isEmpty else { throw refuse("missing unit") }
            guard let unit = Self.units[unitName] else { throw refuse("unknown unit \(String(unitName).debugDescription)") }

            // Leading digits beyond these bounds would exceed the range or the
            // nanosecond precision anyway, and keep the arithmetic in Int128.
            let whole = parts[0].drop { $0 == "0" }
            guard whole.count <= 20 else { throw refuse("out of range") }
            var nanoseconds = (Int128(whole) ?? 0) * unit
            if parts.count == 2 {
                let fraction = parts[1].prefix(20)
                var scale: Int128 = 1
                for _ in fraction { scale *= 10 }
                nanoseconds += (Int128(fraction) ?? 0) * unit / scale
            }
            total += nanoseconds
            guard total <= limit else { throw refuse("out of range") }
        }
        guard let value = Int64(exactly: negative ? -total : total) else { throw refuse("out of range") }
        self = .nanoseconds(value)
    }
}
