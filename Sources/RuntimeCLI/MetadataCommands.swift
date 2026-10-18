import ArgumentParser
import ContainerRuntime

/// Version output shared by `--version` (ArgumentParser's built-in, fed by
/// `CommandConfiguration.version`) and the short `-v` flag runc also accepts.
enum VersionOutput {
    static var text: String { RuntimeMetadata.versionText }
}

struct Spec: RuntimeLoggingCommand {
    static let configuration = CommandConfiguration(
        commandName: "spec",
        abstract: "Write a starter config.json into a bundle.",
        discussion: "Writes the same starter specification as runc spec, except for the hostname. "
            + "An existing config.json, including a directory or a symlink (even a dangling one), is never "
            + "overwritten. The file is created with mode 0666 minus the umask. With --rootless, the user "
            + "namespace maps container root to the caller's effective UID and GID. The starter asks for features "
            + "this runtime does not run yet (a terminal, the /sys/fs/cgroup mount, and the cgroup and "
            + "user namespaces); edit it before running it here.")

    @OptionGroup var globals: GlobalOptions

    @Option(name: [.customShort("b"), .long],
            help: ArgumentHelp("Directory to write config.json into (default: the current directory).",
                               valueName: "path"))
    var bundle = ""

    @Flag(help: "Generate a spec for a rootless container.")
    var rootless = false

    func validate() throws {
        guard !bundle.utf8.contains(0) else { throw ValidationError("--bundle must contain no NUL") }
    }

    mutating func run() throws {
        do {
            try DefaultSpecification.forCurrentHost(rootless: rootless).write(toBundle: bundle)
        } catch {
            throw CommandFailure.report(error)
        }
    }
}

struct Features: RuntimeLoggingCommand {
    static let configuration = CommandConfiguration(
        commandName: "features",
        abstract: "Show the OCI features this build implements.",
        discussion: "Prints an OCI runtime-spec features document. It lists what this build implements, "
            + "not what the running kernel provides: a cgroup v2 mount, the capabilities the kernel knows, "
            + "and any requested AppArmor profile or SELinux label are checked when a container runs. Surfaces "
            + "that are not implemented, such as idmapped mounts, are reported as empty or disabled. Non-Linux builds "
            + "cannot run containers, so they omit the linux section.")

    @OptionGroup var globals: GlobalOptions

    mutating func run() throws {
        do {
            print(try RuntimeFeatures.current.json(), terminator: "")
        } catch {
            throw CommandFailure.report(error)
        }
    }
}
