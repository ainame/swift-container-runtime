import ArgumentParser
import ContainerRuntime
import SystemPackage

struct Events: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "Display container events such as OOM notifications and resource usage statistics.",
        discussion: "Prints one JSON object per line, as runc does: stats events every --interval and oom events "
            + "as they happen, until the container's cgroup empties or the container is deleted."
    )

    @OptionGroup var globals: GlobalOptions

    @Option(parsing: .unconditional, help:"Set the stats collection interval, as a Go duration such as 5s or 1m30s.")
    var interval = "5s"

    @Flag(help: "Display the container's stats then exit.")
    var stats = false

    @Argument(help: "Container ID.")
    var id: String

    /// A malformed duration is a usage error. A nonpositive one is checked
    /// only after the container is found, in runc's order.
    mutating func validate() throws {
        _ = try validatedID(id)
        do {
            _ = try parseGoDuration(interval)
        } catch {
            throw ValidationError("invalid value \"\(interval)\" for flag -interval: \(error)")
        }
    }

    mutating func run() throws {
        do {
            let nanoseconds = try parseGoDuration(interval)
            try globals.lifecycle().events(id: ContainerID(id), interval: nanoseconds, statsOnly: stats) { event in
                // Each event is written whole, so a reader sees complete lines.
                _ = try FileDescriptor.standardOutput.writeAll((event.json(id: id) + "\n").utf8)
            }
        } catch {
            throw failure(error)
        }
    }
}
