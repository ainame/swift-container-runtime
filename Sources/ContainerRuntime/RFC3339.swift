/// UTC timestamps with Go-compatible fractional-second formatting.
enum RFC3339 {
    /// Formats a UTC instant as RFC 3339 with nanoseconds, trimming trailing
    /// zeros as Go's RFC3339Nano (used by runc) does.
    static func format(seconds: Int64, nanoseconds: Int64) -> String {
        // Split whole seconds without losing the day before the Unix epoch.
        let days = seconds >= 0 ? seconds / 86_400 : (seconds - 86_399) / 86_400
        let secondOfDay = seconds - days * 86_400
        // Convert epoch days to a Gregorian date (Howard Hinnant's days-to-civil algorithm).
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)

        func padded(_ value: Int64, _ width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        // Render whole seconds, then trim insignificant fractional zeros.
        var text = "\(padded(year, 4))-\(padded(month, 2))-\(padded(day, 2))T"
            + "\(padded(secondOfDay / 3600, 2)):\(padded(secondOfDay % 3600 / 60, 2)):\(padded(secondOfDay % 60, 2))"
        if nanoseconds > 0 {
            var fraction = padded(nanoseconds, 9)
            while fraction.hasSuffix("0") { fraction.removeLast() }
            text += "." + fraction
        }
        return text + "Z"
    }
}
