#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SystemPackage
import Testing
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import ContainerRuntime

/// Runs `body` in a fresh directory, then removes the listed entries and the directory itself.
private func withBundle(cleanup: [String] = ["config.json"], _ body: (FilePath) throws -> Void) throws {
    var template = Array("/tmp/swift-runtime-spec-XXXXXX".utf8CString)
    let created = template.withUnsafeMutableBufferPointer { buffer in
        unsafe mkdtemp(buffer.baseAddress!) != nil
    }
    try #require(created)
    let directory = template.withUnsafeBufferPointer { buffer in
        unsafe FilePath(platformString: buffer.baseAddress!)
    }
    defer {
        for name in cleanup {
            let entry = directory.appending(name)
            // Entries are files, symlinks, or empty directories.
            if unsafe entry.withPlatformString({ unsafe unlink($0) }) != 0 {
                _ = unsafe entry.withPlatformString { unsafe rmdir($0) }
            }
        }
        _ = unsafe directory.withPlatformString { unsafe rmdir($0) }
    }
    try body(directory)
}

private func writeFile(_ path: FilePath, _ contents: String) throws {
    let descriptor = try FileDescriptor.open(
        path, .writeOnly, options: [.create, .exclusiveCreate], permissions: [.ownerReadWrite])
    try descriptor.closeAfter { _ = try descriptor.writeAll(contents.utf8) }
}

private func readFile(_ path: FilePath) throws -> String {
    let descriptor = try FileDescriptor.open(path, .readOnly)
    return try descriptor.closeAfter {
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = try chunk.withUnsafeMutableBytes { bytes in unsafe try descriptor.read(into: bytes) }
            if count == 0 { break }
            bytes += chunk[..<count]
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private func exists(_ path: FilePath) -> Bool {
    var status = stat()
    return unsafe path.withPlatformString { unsafe lstat($0, &status) } == 0
}

private func decode(_ bytes: [UInt8]) throws -> DefaultSpecification {
    try JSONDecoder().decode(DefaultSpecification.self, from: Data(bytes))
}

// MARK: - Version

@Test func versionTextFollowsRuncLayoutWithoutInventingACommit() {
    let lines = RuntimeMetadata.versionText.split(separator: "\n").map(String.init)
    #expect(lines.first == "swift-container-runtime version \(RuntimeMetadata.version)")
    #expect(lines.last == "spec: 1.3.0")
    #expect(lines.contains { $0.hasPrefix("commit:") } == (RuntimeMetadata.commit != nil))
    #expect(!RuntimeMetadata.version.isEmpty)
}

// MARK: - Starter spec

@Test func exampleMatchesRuncStarterFields() throws {
    let spec = try decode(try DefaultSpecification.example(cgroupNamespace: false).json())
    #expect(spec.ociVersion == RuntimeMetadata.ociVersion)
    #expect(spec.root == .init(path: "rootfs", readonly: true))
    let process = try #require(spec.process)
    #expect(process.terminal == true)
    #expect(process.user == .init(uid: 0, gid: 0))
    #expect(process.args == ["sh"])
    #expect(process.cwd == "/")
    #expect(process.noNewPrivileges == true)
    #expect(process.capabilities?.bounding == ["CAP_AUDIT_WRITE", "CAP_KILL", "CAP_NET_BIND_SERVICE"])
    #expect(process.rlimits == [.init(type: "RLIMIT_NOFILE", hard: 1024, soft: 1024)])
    let mounts = try #require(spec.mounts)
    #expect(mounts.map(\.destination)
        == ["/proc", "/dev", "/dev/pts", "/dev/shm", "/dev/mqueue", "/sys", "/sys/fs/cgroup"])
    #expect(mounts[0].options == nil)
    let linux = try #require(spec.linux)
    #expect(linux.namespaces?.map(\.type) == ["pid", "network", "ipc", "uts", "mount"])
    #expect(linux.resources?.devices == [.init(allow: false, access: "rwm")])
    #expect(linux.uidMappings == nil && linux.gidMappings == nil)
    #expect(linux.maskedPaths?.count == 10)
    #expect(linux.readonlyPaths?.count == 5)
}

@Test func exampleOmitsUnsetKeysLikeGo() throws {
    let text = String(decoding: try DefaultSpecification.example(cgroupNamespace: false).json(), as: UTF8.self)
    #expect(!text.contains("uidMappings"))
    #expect(!text.contains("inheritable"))
    #expect(!text.contains("ambient"))
    #expect(text.hasSuffix("}\n"))
}

@Test func cgroupNamespaceFollowsUnifiedHierarchyProbe() {
    let namespaces = DefaultSpecification.example(cgroupNamespace: true).linux?.namespaces?.map(\.type)
    #expect(namespaces == ["pid", "network", "ipc", "uts", "mount", "cgroup"])
}

@Test func rootlessMapsInjectedIDsAndAdjustsMounts() throws {
    let spec = try decode(
        try DefaultSpecification.example(cgroupNamespace: true).rootless(effectiveUID: 1234, effectiveGID: 5678).json())
    let linux = try #require(spec.linux)
    #expect(linux.namespaces?.map(\.type) == ["pid", "ipc", "uts", "mount", "cgroup", "user"])
    #expect(linux.uidMappings == [.init(containerID: 0, hostID: 1234, size: 1)])
    #expect(linux.gidMappings == [.init(containerID: 0, hostID: 5678, size: 1)])
    #expect(linux.resources == nil)
    let mounts = try #require(spec.mounts)
    let sys = try #require(mounts.first { $0.destination == "/sys" })
    #expect(sys == .init(destination: "/sys", type: "none", source: "/sys",
                         options: ["rbind", "nosuid", "noexec", "nodev", "ro"]))
    let pts = try #require(mounts.first { $0.destination == "/dev/pts" })
    #expect(pts.options == ["nosuid", "noexec", "newinstance", "ptmxmode=0666", "mode=0620"])
    #expect(mounts.first { $0.destination == "/proc" }?.options == nil)
}

@Test func rootlessDoesNotDuplicateUserNamespace() {
    let twice = DefaultSpecification.example(cgroupNamespace: false)
        .rootless(effectiveUID: 1, effectiveGID: 1).rootless(effectiveUID: 2, effectiveGID: 3)
    #expect(twice.linux?.namespaces?.filter { $0.type == "user" }.count == 1)
    #expect(twice.linux?.uidMappings?.first?.hostID == 2)
}

// MARK: - Writing config.json

@Test func writeCreatesConfigInBundle() throws {
    try withBundle { bundle in
        let spec = DefaultSpecification.example(cgroupNamespace: false)
        let path = try spec.write(toBundle: bundle.string)
        #expect(path == bundle.appending("config.json"))
        #expect(try decode(Array(try readFile(path).utf8)) == spec)
        var status = stat()
        #expect(unsafe path.withPlatformString { unsafe stat($0, &status) } == 0)
        // 0o666 minus the umask: never executable, always owner-writable for typical umasks.
        #expect(status.st_mode & 0o111 == 0)
        #expect(status.st_mode & 0o600 == 0o600)
    }
}

@Test func writeRefusesExistingRegularFile() throws {
    try withBundle { bundle in
        let config = bundle.appending("config.json")
        try writeFile(config, "keep")
        #expect(throws: RuntimeError.self) {
            try DefaultSpecification.example(cgroupNamespace: false).write(toBundle: bundle.string)
        }
        #expect(try readFile(config) == "keep")
    }
}

@Test func writeRefusesExistingDirectory() throws {
    try withBundle { bundle in
        let config = bundle.appending("config.json")
        try #require(unsafe config.withPlatformString { unsafe mkdir($0, 0o755) } == 0)
        let error = #expect(throws: RuntimeError.self) {
            try DefaultSpecification.example(cgroupNamespace: false).write(toBundle: bundle.string)
        }
        #expect(error?.description.contains("exists. Remove it first") == true)
    }
}

@Test func writeRefusesSymlinkToExistingFile() throws {
    try withBundle(cleanup: ["config.json", "target"]) { bundle in
        let target = bundle.appending("target")
        try writeFile(target, "keep")
        try #require(unsafe bundle.appending("config.json").withPlatformString { unsafe symlink("target", $0) } == 0)
        #expect(throws: RuntimeError.self) {
            try DefaultSpecification.example(cgroupNamespace: false).write(toBundle: bundle.string)
        }
        #expect(try readFile(target) == "keep")
    }
}

@Test func writeRefusesDanglingSymlink() throws {
    try withBundle(cleanup: ["config.json", "missing"]) { bundle in
        try #require(unsafe bundle.appending("config.json").withPlatformString { unsafe symlink("missing", $0) } == 0)
        #expect(throws: RuntimeError.self) {
            try DefaultSpecification.example(cgroupNamespace: false).write(toBundle: bundle.string)
        }
        #expect(!exists(bundle.appending("missing")))
    }
}

@Test func writeRejectsMissingBundleAndNUL() throws {
    try withBundle(cleanup: []) { bundle in
        let spec = DefaultSpecification.example(cgroupNamespace: false)
        let missing = bundle.appending("absent")
        #expect(throws: RuntimeError.self) { try spec.write(toBundle: missing.string) }
        #expect(!exists(missing))
        #expect(throws: RuntimeError.self) { try spec.write(toBundle: bundle.string + "\0x") }
        #expect(!exists(bundle.appending("config.json")))
    }
}

// MARK: - Features

@Test func featuresReportOnlyImplementedSurfaces() throws {
    let linux = RuntimeFeatures.report(linux: true)
    #expect(linux.ociVersionMin == "1.0.0")
    #expect(linux.ociVersionMax == RuntimeMetadata.ociVersion)
    #expect(linux.hooks == [])
    #expect(linux.mountOptions == ["nodev", "noexec", "nosuid", "strictatime", "ro", "rw", "dev", "exec", "suid", "bind", "rbind", "private", "rprivate"])
    let section = try #require(linux.linux)
    #expect(section.namespaces == ["pid", "mount", "uts", "ipc", "network"])
    #expect(section.capabilities == CapabilitySet.knownNames)
    #expect(section.cgroup == .init(v1: false, v2: true, systemd: false, systemdUser: false, rdma: false))
    #expect(section.seccomp?.enabled == true)
    for surface in [ section.apparmor, section.selinux, section.netDevices, section.mountExtensions?.idmap] {
        #expect(surface?.enabled == false)
    }
    #expect(section.intelRdt?.enabled == false)

    let text = try linux.json()
    #expect(!text.contains("annotations"))
    #expect(!text.contains("memoryPolicy"))
    #expect(try JSONDecoder().decode(RuntimeFeatures.self, from: Data(text.utf8)) == linux)
}

@Test func featuresOffLinuxClaimNoContainerSupport() {
    let other = RuntimeFeatures.report(linux: false)
    #expect(other.linux == nil)
    #expect(other.mountOptions == [])
    #expect(other.hooks == [])
    #if !os(Linux)
    #expect(RuntimeFeatures.current == other)
    #endif
}


@Test func pidFileReplacesASymlinkWithoutTouchingItsTarget() throws {
    try withBundle(cleanup: ["init.pid", "target", ".init.pid"]) { directory in
        let target = directory.appending("target")
        let destination = directory.appending("init.pid")
        try writeFile(target, "untouched")
        let linked = unsafe destination.withCString { path in unsafe symlink("target", path) }
        #expect(linked == 0)
        try PIDFile.write(12345, to: destination.string)
        #expect(try readFile(destination) == "12345")
        #expect(try readFile(target) == "untouched")
        #expect(!exists(directory.appending(".init.pid")))
    }
}

@Test func pidFileDoesNotOverwriteAnotherWritersTemporaryFile() throws {
    try withBundle(cleanup: ["init.pid", ".init.pid"]) { directory in
        let destination = directory.appending("init.pid")
        let temporary = directory.appending(".init.pid")
        try writeFile(destination, "old")
        try writeFile(temporary, "other writer")
        #expect(throws: (any Error).self) { try PIDFile.write(12345, to: destination.string) }
        #expect(try readFile(destination) == "old")
        #expect(try readFile(temporary) == "other writer")
    }
}
