import Testing
@testable import ContainerRuntime

private func configuration(_ text: String) throws -> OCIConfiguration.Resources {
    try ResourceUpdate(json: Array(text.utf8)).configuration
}

@Test func quotaAndPeriodUpdatesRetainOnlyTheIntendedCounterpart() throws {
    let initial = try configuration(#"{"cpu":{"quota":50000,"period":200000,"shares":512,"burst":0,"idle":0,"cpus":"1"},"pids":{"limit":32}}"#)
    let quota = ResourceUpdate(cpuQuota: 80000).merged(with: initial)
    #expect(quota.cpu?.quota == 80000 && quota.cpu?.period == 200000)
    #expect(quota.cpu?.shares == 512)
    #expect(quota.cpu?.burst == nil && quota.cpu?.idle == nil && quota.cpu?.cpus == nil)
    #expect(quota.pids == nil)
    let period = ResourceUpdate(cpuPeriod: 300000).merged(with: quota)
    #expect(period.cpu?.quota == 80000 && period.cpu?.period == 300000)
    let empty = ResourceUpdate().merged(with: period)
    #expect(empty.cpu?.quota == 0 && empty.cpu?.period == 0)
    #expect(try CgroupPlan.converted(empty).cpu.max == nil)
}

@Test func memoryAndIdleFixupsMatchRuncUpdate() throws {
    let initial = try configuration(#"{"memory":{"limit":8192,"reservation":4096,"swap":16384,"checkBeforeUpdate":true},"cpu":{"shares":512}}"#)
    let idle = ResourceUpdate(cpuIdle: 1).merged(with: initial)
    #expect(idle.cpu?.shares == 0)
    #expect(idle.memory?.limit == 8192 && idle.memory?.swap == 16384 && idle.memory?.reservation == 4096)
    #expect(idle.memory?.checkBeforeUpdate == false)
    let unlimited = ResourceUpdate(memory: -1).merged(with: initial)
    #expect(unlimited.memory?.swap == 0)
    #expect(try CgroupPlan.converted(unlimited).swapMax == .max)
}

@Test(arguments: [#"{"cpu":{"quota":"bad"}}"#, #"{"memory":{"checkBeforeUpdate":"true"}}"#, #"{"blockIO":{}}"#, #"{"devices":[]}"#, "[]"])
func rejectsMalformedUpdateResources(_ json: String) {
    #expect(throws: RuntimeError.self) { try ResourceUpdate(json: Array(json.utf8)) }
}

@Test func memoryUsageChecksRejectEqualUsageAndCombinedLimitFirst() throws {
    let both = MemoryUsageCheck(limit: 100, swap: 100)
    do {
        try both.validate(current: 100)
        Issue.record("expected refusal")
    } catch {
        #expect(String(describing: error).contains("memory+swap limit"))
    }
    #expect(throws: RuntimeError.self) { try MemoryUsageCheck(limit: 100, swap: 0).validate(current: 100) }
    try both.validate(current: 99)
    try MemoryUsageCheck(limit: -1, swap: -1).validate(current: UInt64.max)
}

@Test func memoryCheckRunsAfterPidsAndBeforeAnyMemoryWrite() throws {
    let raw = try configuration(#"{"pids":{"limit":8},"memory":{"limit":100,"checkBeforeUpdate":true},"cpu":{"quota":10000}}"#)
    let converted = try CgroupPlan.converted(raw)
    let check = try #require(converted.memoryCheck)
    var operations: [String] = []
    do {
        try converted.apply(in: "/test", checkMemory: {
            operations.append("check")
            try check.validate(current: 100)
        }) { file, _ in
            operations.append(file)
            return nil
        }
        Issue.record("memory usage check should refuse the request")
    } catch {
        #expect(operations == ["pids.max", "check"])
    }
}
