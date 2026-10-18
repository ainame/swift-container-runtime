import ArgumentParser
import ContainerRuntime
import Testing
@testable import RuntimeCLI

// Direct parser cases isolate each command; the root cases verify public registration.

@Test func specDefaultsToCurrentDirectoryWithoutRootless() throws {
    let command = try Spec.parse([])
    #expect(command.bundle == "")
    #expect(command.rootless == false)
}

@Test func specParsesBundleAndRootless() throws {
    let short = try Spec.parse(["-b", "/srv/bundle", "--rootless"])
    #expect(short.bundle == "/srv/bundle")
    #expect(short.rootless)
    let long = try Spec.parse(["--bundle", "relative/dir"])
    #expect(long.bundle == "relative/dir")
    #expect(!long.rootless)
}

@Test func specRejectsArgumentsAndNULBundle() {
    #expect(throws: (any Error).self) { try Spec.parse(["extra"]) }
    #expect(throws: (any Error).self) { try Spec.parse(["--bundle", "a\0b"]) }
}

@Test func specHelpWarnsThatTheStarterIsNotRunnableYet() {
    let help = Spec.helpMessage()
    #expect(help.contains("--rootless"))
    // Help wraps lines, so check single words: the no-overwrite rule and the runnability warning.
    #expect(help.contains("overwritten"))
    #expect(help.contains("terminal"))
}

@Test func featuresTakesNoArguments() throws {
    _ = try Features.parse([])
    #expect(throws: (any Error).self) { try Features.parse(["extra"]) }
}

@Test func versionOutputUsesRuntimeMetadata() {
    #expect(VersionOutput.text == RuntimeMetadata.versionText)
    #expect(VersionOutput.text.hasPrefix("srunc version "))
}

@Test func metadataCommandsAreRegisteredAtTheRoot() throws {
    #expect(try RuntimeCommand.parseAsRoot(["spec"]) is Spec)
    #expect(try RuntimeCommand.parseAsRoot(["features"]) is Features)
    let version = try #require(RuntimeCommand.parseAsRoot(["-v"]) as? RuntimeCommand)
    #expect(version.shortVersion)
    #expect(RuntimeCommand.configuration.version == RuntimeMetadata.versionText)
}
