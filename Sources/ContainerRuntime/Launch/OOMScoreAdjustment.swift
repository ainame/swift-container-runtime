import SystemPackage

/// Decimal procfs input prepared before fork. Only the launcher writes it;
/// descendants inherit the score without changing the supervisor or caller.
struct OOMScoreAdjustment {
    let bytes: [UInt8]?

    init(_ value: Int32?) {
        bytes = value.map { Array(String($0).utf8) }
    }

    func apply() -> LaunchFailure? {
        guard let bytes else { return nil }
        do {
            try Kernel.Process.setOOMScoreAdjustment(bytes)
            return nil
        } catch {
            return LaunchFailure(stage: .oomScoreAdjustment, error: error)
        }
    }
}
