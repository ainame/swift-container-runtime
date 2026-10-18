import SystemPackage

/// `process.oomScoreAdj` as decimal procfs input, prepared before fork. Only
/// the launcher writes it, before it joins or creates namespaces; the init and
/// its descendants inherit the score without changing the supervisor or caller.
struct OOMScoreAdjustment {
    /// The bytes written to /proc/self/oom_score_adj; nil leaves it inherited.
    let bytes: [UInt8]?

    init(_ value: Int32?) {
        bytes = value.map { Array(String($0).utf8) }
    }

    /// Writes the score in the launcher. Returns nil or the failure.
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
