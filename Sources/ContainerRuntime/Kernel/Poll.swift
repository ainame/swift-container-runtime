#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
#if os(Linux)
import LinuxAPI
#endif
import SystemPackage

/// poll(2) event bits.
struct PollEvents: OptionSet, Sendable {
    let rawValue: Int16

    static let input = PollEvents(rawValue: Int16(POLLIN))
    static let hangup = PollEvents(rawValue: Int16(POLLHUP))
    static let error = PollEvents(rawValue: Int16(POLLERR))
    #if os(Linux)
    /// The peer shut down its writing side (POLLRDHUP).
    static let peerHangup = PollEvents(rawValue: Int16(POLLRDHUP))
    #else
    static let peerHangup: PollEvents = []
    #endif
}

extension OwnedFileDescriptor {
    /// Polls with a monotonic deadline, so interruption cannot restart the full
    /// timeout. Empty on timeout; `.error` when poll fails or the descriptor
    /// is invalid or unusable.
    func poll(_ events: PollEvents, timeout: Duration) -> PollEvents {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        // Keep ownership through every retry and recompute only the remaining wait.
        return (try? withDescriptor { descriptor -> PollEvents in
            while true {
                var target = pollfd(fd: descriptor.rawValue, events: events.rawValue, revents: 0)
                let result = unsafe pollOne(&target, clock.now.duration(to: deadline).pollTimeout)
                if result > 0 { return target.revents & Int16(POLLNVAL) == 0 ? PollEvents(rawValue: target.revents) : .error }
                if result == 0 { return [] }
                if errno != EINTR { return .error }
                guard clock.now < deadline else { return [] }
            }
        }) ?? .error
    }
}

/// poll(2) on one descriptor; at file scope, `poll` names the libc function
/// rather than the method above, whichever libc this is.
private func pollOne(_ target: UnsafeMutablePointer<pollfd>, _ timeout: Int32) -> Int32 {
    unsafe poll(target, 1, timeout)
}

extension Duration {
    /// poll(2)'s timeout in milliseconds: rounded up so a wakeup is never
    /// early, zero for a past deadline, and capped at the Int32 range.
    var pollTimeout: Int32 {
        guard self > .zero else { return 0 }
        let (seconds, attoseconds) = components
        guard seconds < Int64(Int32.max / 1000) + 1 else { return .max }
        return Int32(clamping: seconds * 1000 + (attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000)
    }
}
