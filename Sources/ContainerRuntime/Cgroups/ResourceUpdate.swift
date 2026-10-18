#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A strict resource patch. Omitted fields follow runc update's saved-config
/// rules; they are not uniformly equivalent to retaining the old setting.
public struct ResourceUpdate: Sendable {
    var configuration: OCIConfiguration.Resources

    public init(json: [UInt8]) throws {
        do { configuration = try JSONDecoder().decode(OCIConfiguration.Resources.self, from: Data(json)) }
        catch { throw RuntimeError("resources JSON: \(error)") }
    }

    public init(
        memory: Int64? = nil, memorySwap: Int64? = nil, memoryReservation: Int64? = nil,
        cpuQuota: Int64? = nil, cpuPeriod: UInt64? = nil, cpuShares: UInt64? = nil,
        cpuBurst: UInt64? = nil, cpuIdle: Int64? = nil, cpusetCpus: String? = nil,
        cpusetMems: String? = nil, pidsLimit: Int64? = nil
    ) {
        var resources = OCIConfiguration.Resources()
        // Preserve optional memory fields for the later saved-state merge.
        var mem = OCIConfiguration.Memory()
        mem.limit = memory
        mem.swap = memorySwap
        mem.reservation = memoryReservation
        resources.memory = mem
        // CPU zero and absence have distinct update behavior.
        var cpu = OCIConfiguration.CPU()
        cpu.quota = cpuQuota
        cpu.period = cpuPeriod
        cpu.shares = cpuShares
        cpu.burst = cpuBurst
        cpu.idle = cpuIdle
        cpu.cpus = cpusetCpus
        cpu.mems = cpusetMems
        resources.cpu = cpu
        // An omitted pids limit means no pids write.
        var pids = OCIConfiguration.Pids()
        pids.limit = pidsLimit
        resources.pids = pids
        configuration = resources
    }

    /// runc's update.go fixes up the request, then merges it into the saved
    /// configuration. Burst/idle/cpusets/pids are replaced even when absent.
    func merged(with previous: OCIConfiguration.Resources) -> OCIConfiguration.Resources {
        var result = previous
        var memory = previous.memory ?? OCIConfiguration.Memory()
        if let limit = configuration.memory?.limit { memory.limit = limit }
        if let reservation = configuration.memory?.reservation { memory.reservation = reservation }
        if let swap = configuration.memory?.swap { memory.swap = swap }
        else if configuration.memory?.limit == -1 { memory.swap = 0 }
        memory.checkBeforeUpdate = configuration.memory?.checkBeforeUpdate ?? false
        result.memory = memory

        // Exactly one nonzero quota/period preserves its old counterpart.
        // With both zero, metadata resets while cpu.max is left untouched.
        var cpu = previous.cpu ?? OCIConfiguration.CPU()
        let quota = configuration.cpu?.quota ?? 0
        let period = configuration.cpu?.period ?? 0
        if (quota == 0) == (period == 0) {
            cpu.quota = quota
            cpu.period = period
        } else if quota != 0 { cpu.quota = quota }
        else { cpu.period = period }
        if let shares = configuration.cpu?.shares { cpu.shares = shares }
        else if configuration.cpu?.idle != nil { cpu.shares = 0 }
        cpu.burst = configuration.cpu?.burst
        cpu.idle = configuration.cpu?.idle
        cpu.cpus = configuration.cpu?.cpus
        cpu.mems = configuration.cpu?.mems
        result.cpu = cpu
        result.pids = configuration.pids?.limit == nil ? nil : configuration.pids
        return result
    }
}

/// runc's best-effort pre-update check uses memory.current, including for
/// the combined memory+swap threshold. It does not add swap.current.
struct MemoryUsageCheck: Sendable, Equatable {
    let limit: Int64
    let swap: Int64

    func validate(current: UInt64) throws {
        if swap > 0, UInt64(swap) <= current {
            throw RuntimeError("rejecting memory+swap limit \(swap) <= usage \(current)")
        }
        if limit > 0, UInt64(limit) <= current {
            throw RuntimeError("rejecting memory limit \(limit) <= usage \(current)")
        }
    }
}
