import ArgumentParser
import Testing
@testable import RuntimeCLI

@Test func parsesEventsDefaults() throws {
    let command = try #require(RuntimeCommand.parseAsRoot(["events", "box"]) as? Events)
    #expect(command.interval == "5s")
    #expect(!command.stats)
    #expect(command.id == "box")
}

@Test func parsesEventsOptions() throws {
    let command = try #require(RuntimeCommand.parseAsRoot(["events", "--stats", "--interval", "1m30s", "box"]) as? Events)
    #expect(command.interval == "1m30s")
    #expect(command.stats)
}

/// Zero and negative durations parse; runc rejects them only after the
/// container lookup, so that check belongs to the lifecycle.
@Test(arguments: ["0", "-1s"])
func acceptsNonpositiveEventsIntervalsAtParse(interval: String) throws {
    let command = try #require(RuntimeCommand.parseAsRoot(["events", "--interval", interval, "box"]) as? Events)
    #expect(command.interval == interval)
}

@Test(arguments: [
    ["events"],
    ["events", "--interval", "5", "box"],
    ["events", "--interval", "5x", "box"],
    ["events", "../box"],
])
func rejectsInvalidEventsArguments(arguments: [String]) {
    #expect(throws: (any Error).self) { try RuntimeCommand.parseAsRoot(arguments) }
}
