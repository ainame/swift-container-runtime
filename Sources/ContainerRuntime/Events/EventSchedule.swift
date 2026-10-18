/// Saturating nanosecond arithmetic for the event stream's periodic samples.
enum EventSchedule {
    /// The offset of the first stats tick after `elapsed`, for ticks every
    /// `interval` nanoseconds from the start of a stream. Missed ticks are
    /// skipped in constant time, as runc drops ticks for a slow reader; an
    /// offset beyond Int64 saturates.
    static func next(after elapsed: Int64, interval: Int64) -> Int64 {
        precondition(interval > 0)
        let (ticks, countOverflow) = (max(elapsed, 0) / interval).addingReportingOverflow(1)
        let (offset, overflow) = ticks.multipliedReportingOverflow(by: interval)
        return countOverflow || overflow ? .max : offset
    }

    /// A non-negative duration in whole nanoseconds, saturating at Int64.max.
    static func nanoseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        guard seconds >= 0 else { return 0 }
        let (whole, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return .max }
        let (total, sumOverflow) = whole.addingReportingOverflow(attoseconds / 1_000_000_000)
        return sumOverflow ? .max : total
    }
}
