import SystemPackage

extension Kernel.Process {
    /// Write before setns/unshare, setuid, seccomp or rlimits. A child inherits
    /// its parent's oom_score_adj. Lowering it can require CAP_SYS_RESOURCE;
    /// permission errors are never ignored or replaced with an inherited value.
    static func setOOMScoreAdjustment(_ bytes: [UInt8]) throws(Errno) {
        #if os(Linux)
        let owner = try Kernel.File.open("/proc/self/oom_score_adj", .writeOnly)
        try owner.borrowDescriptor { descriptor throws(Errno) in
            guard try Kernel.File.write(descriptor, bytes.span.bytes) == bytes.count else { throw .ioError }
        }
        #else
        throw .noFunction
        #endif
    }
}
