#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing

/// Runtime files that still import libc directly; each migration step to
/// `Kernel/` removes entries until the list is empty.
private let pendingMigration: Set<String> = [
    "Launch/ExecLaunch.swift",
    "Launch/LaunchProtocol.swift",
    "Launch/NamespaceCommand.swift",
    "Launch/NamespaceLauncher.swift",
    "Launch/OCILaunch.swift",
    "Launch/RootFilesystemSetup.swift",
    "Launch/WorkloadSetup.swift",
    "Specification/PathControls.swift",
]

/// Only `Kernel/` may import libc or `LinuxAPI`; the rest of the runtime uses
/// Kernel's Swift API (see docs/code-organization.md).
@Test func onlyKernelImportsLibc() throws {
    let sources = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/ContainerRuntime")
    let forbidden = ["Glibc", "Musl", "Darwin", "LinuxAPI"]
    var importing: Set<String> = []
    for directory in try FileManager.default.contentsOfDirectory(atPath: sources.path) where directory != "Kernel" {
        let folder = sources.appending(path: directory)
        for file in try FileManager.default.contentsOfDirectory(atPath: folder.path) where file.hasSuffix(".swift") {
            let text = try String(contentsOf: folder.appending(path: file), encoding: .utf8)
            let imports = text.split(separator: "\n").contains { line in
                let words = line.split(separator: " ")
                return words.count == 2 && words[0] == "import" && forbidden.contains(String(words[1]))
            }
            if imports { importing.insert("\(directory)/\(file)") }
        }
    }
    #expect(importing.subtracting(pendingMigration).sorted() == [], "import libc only in Kernel/")
    #expect(pendingMigration.subtracting(importing).sorted() == [], "remove migrated files from pendingMigration")
}
