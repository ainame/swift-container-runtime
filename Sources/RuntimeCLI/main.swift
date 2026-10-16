import ContainerRuntime

let usage = """
Usage: swift-container-runtime namespace-run [--hostname NAME] -- /absolute/program [args...]

Experimental Linux namespace lab: new UTS, PID, and mount namespaces.
Shares the caller's filesystem, network, user identity, and privileges.
This is not yet an OCI runtime or a security sandbox.
"""

func main(_ arguments: [String]) throws -> Int32 {
    if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] {
        print(usage)
        return 0
    }
    guard arguments.first == "namespace-run" else {
        throw RuntimeError("unknown command: \(arguments[0]); use --help")
    }
    var hostname = "swiftbox"
    var index = 1
    while index < arguments.count && arguments[index] != "--" {
        guard arguments[index] == "--hostname", index + 1 < arguments.count else {
            throw RuntimeError("expected --hostname NAME or -- before the executable")
        }
        hostname = arguments[index + 1]
        index += 2
    }
    guard index < arguments.count else {
        throw RuntimeError("missing -- and absolute executable path")
    }
    return try NamespaceCommand(hostname: hostname, arguments: Array(arguments.dropFirst(index + 1))).run()
}

do {
    RuntimeDiagnostics.exit(try main(Array(CommandLine.arguments.dropFirst())))
} catch {
    RuntimeDiagnostics.writeError("swift-container-runtime: \(error)")
    RuntimeDiagnostics.exit(125)
}
