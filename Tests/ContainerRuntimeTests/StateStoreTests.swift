#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SystemPackage
import Testing
@testable import ContainerRuntime

private let box = try! ContainerID("box")

private func withTemporaryRoot(_ body: (FilePath) throws -> Void) throws {
    var template = Array("/tmp/swift-runtime-state-XXXXXX".utf8CString)
    let created = template.withUnsafeMutableBufferPointer { buffer in
        unsafe mkdtemp(buffer.baseAddress!) != nil
    }
    try #require(created)
    let directory = template.withUnsafeBufferPointer { buffer in
        unsafe FilePath(platformString: buffer.baseAddress!)
    }
    defer { _ = unsafe directory.withPlatformString { unsafe rmdir($0) } }
    try body(directory)
}

private func sampleRecord(created: Date = Date()) throws -> ContainerRecord {
    let configuration = try OCIConfiguration.decode(Array(#"""
    {"ociVersion": "1.0.2", "root": {"path": "rootfs"}, "process": {"args": ["/bin/true"], "cwd": "/"},
     "linux": {"namespaces": [{"type": "mount"}]}}
    """#.utf8))
    let plan = try OCIRunPlan(configuration, bundle: FilePath("/srv/b"), rootfs: FilePath("/srv/b/rootfs"))
    return ContainerRecord(id: box, plan: plan, created: created)
}

@Test func recordsCreationTimeAsRFC3339UTC() throws {
    let record = try sampleRecord(created: Date(timeIntervalSince1970: 1_700_000_000.5))
    #expect(record.created == "2023-11-14T22:13:20.500Z")
}

@Test func createIsExclusiveAndDestroyRemovesState() throws {
    try withTemporaryRoot { path in
        let root = try #require(try StateRoot.open(path, create: true))
        let container = try LockedContainer.create(in: root, id: box)
        let record = try sampleRecord()
        try container.writeRecord(record)
        #expect(try container.readRecord() == record)
        #expect(try !container.directory.contains(StateFile.pendingRecord))
        #expect(throws: LifecycleError.alreadyExists(box)) { _ = try LockedContainer.create(in: root, id: box) }
        try container.destroy()
        #expect(throws: LifecycleError.notFound(box)) { _ = try root.openContainer(box) }
        // The next create with the same ID succeeds.
        let again = try LockedContainer.create(in: root, id: box)
        #expect(try again.readRecord() == nil)
        try again.destroy()
    }
}

/// Enough long names that readdir refills its buffer several times while
/// Swift allocates between calls; every entry must be listed without a
/// stale-errno failure.
@Test func directoryEntriesListsLargeDirectory() throws {
    try withTemporaryRoot { path in
        let directory = OwnedFileDescriptor(
            takingOwnershipOf: try FileDescriptor.open(path, .readOnly, options: [.directory, .closeOnExec])
        )
        let expected = (0..<600).map { "entry-\($0)-" + String(repeating: "x", count: 200) }
        defer {
            for name in expected { _ = try? directory.withDescriptor { unsafe unlinkat($0.rawValue, name, 0) } }
        }
        for name in expected {
            var file = OwnedFileDescriptor(takingOwnershipOf: try FileDescriptor.open(
                path.appending(name), .writeOnly, options: [.create, .exclusiveCreate, .closeOnExec],
                permissions: .ownerReadWrite
            ))
            try file.close()
        }
        #expect(try directory.directoryEntries().sorted() == expected.sorted())
    }
}

@Test func oldGenerationCannotLockOrRemoveReplacement() throws {
    try withTemporaryRoot { path in
        let root = try #require(try StateRoot.open(path, create: true))
        let old = try LockedContainer.create(in: root, id: box)
        try old.writeRecord(sampleRecord())
        try old.destroy()
        old.unlock()

        // A retained descriptor names the removed inode, never the new ID.
        let replacement = try LockedContainer.create(in: root, id: box)
        defer { try? replacement.destroy() }
        let record = try sampleRecord()
        try replacement.writeRecord(record)
        #expect(throws: LifecycleError.notFound(box)) { try old.lock() }
        try old.destroy()
        #expect(try replacement.readRecord() == record)
        #expect(try root.contains(replacement.directory))
    }
}

@Test func membershipLockUsesIndependentDescriptionAndReleasesOnThrow() throws {
    try withTemporaryRoot { path in
        let root = try #require(try StateRoot.open(path, create: true))
        struct Interrupted: Error {}
        #expect(throws: Interrupted.self) {
            try root.withMembershipLock { () throws -> Void in
                // The stored root descriptor must not share the lock's open
                // file description; flock would otherwise be reentrant.
                let result = try root.descriptor.withDescriptor { flock($0.rawValue, LOCK_SH | LOCK_NB) }
                let code = errno
                #expect(result == -1 && code == EWOULDBLOCK)
                throw Interrupted()
            }
        }

        // Unwinding releases the temporary root lock even on failure.
        let result = try root.descriptor.withDescriptor { flock($0.rawValue, LOCK_EX | LOCK_NB) }
        #expect(result == 0)
        _ = try root.descriptor.withDescriptor { flock($0.rawValue, LOCK_UN) }
    }
}

/// dup has the same flock sharing semantics as an inherited descriptor,
/// without forking Swift Testing's multithreaded process.
private func detachedDuplicate(in root: StateRoot) throws -> OwnedFileDescriptor {
    let container = try LockedContainer.create(in: root, id: box)
    let raw = try container.directory.descriptor.withDescriptor { dup($0.rawValue) }
    try #require(raw >= 0)
    let duplicate = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))

    // Detaching closes the owner's descriptor and prevents its deinit from
    // unlocking the shared flock retained by the duplicate.
    container.detachInForkedChild()
    #expect(throws: Errno.badFileDescriptor) { try container.directory.descriptor.withDescriptor { _ in } }
    return duplicate
}

@Test func childDetachDoesNotUnlockSharedDescription() throws {
    try withTemporaryRoot { path in
        let root = try #require(try StateRoot.open(path, create: true))
        var duplicate = try detachedDuplicate(in: root)
        let observer = try root.openContainer(box)
        #expect(try ContainerObservation.read(from: observer).status == .creating)

        // Only closing the final shared reference releases this flock.
        try duplicate.close()
        #expect(try ContainerObservation.read(from: observer).status == .stopped)
        let cleanup = try LockedContainer.acquire(in: root, id: box)
        try cleanup.destroy()
    }
}

@Test func recordWithoutInitIsCreatingOnlyWhileLocked() throws {
    try withTemporaryRoot { path in
        let root = try #require(try StateRoot.open(path, create: true))
        let container = try LockedContainer.create(in: root, id: box)
        defer { try? container.destroy() }
        let record = try sampleRecord()
        try container.writeRecord(record)
        // The creator itself treats an init-less record as an aborted create.
        #expect(try container.status(of: record) == .stopped)
        let observer = try root.openContainer(box)
        #expect(try ContainerObservation.read(from: observer).status == .creating)
        container.unlock()
        #expect(try ContainerObservation.read(from: observer).status == .stopped)
        try container.lock()
    }
}

@Test func recordedInitThatIsGoneIsStopped() throws {
    try withTemporaryRoot { path in
        let root = try #require(try StateRoot.open(path, create: true))
        let container = try LockedContainer.create(in: root, id: box)
        defer { try? container.destroy() }
        var record = try sampleRecord()
        // A live process (the test runner's parent) with a different start time.
        let parent = try ProcFS.identity(of: getppid())
        record.initProcess = InitIdentity(pid: parent.pid, startTime: parent.startTime + 1, bootID: parent.bootID)
        try container.writeRecord(record)
        #expect(try container.status(of: record) == .stopped)
    }
}

@Test func stateRootRejectsUnsafeDirectories() throws {
    try withTemporaryRoot { path in
        let shared = path.appending("shared")
        let made = unsafe shared.withPlatformString { unsafe mkdir($0, 0o700) }
        // chmod is not affected by the umask.
        let opened = unsafe shared.withPlatformString { unsafe chmod($0, 0o777) }
        try #require(made == 0 && opened == 0)
        #expect(throws: RuntimeError.self) { try StateRoot.open(shared, create: false) }
        let link = path.appending("link")
        let linked = unsafe link.withPlatformString { unsafe symlink("shared", $0) }
        try #require(linked == 0)
        #expect(throws: RuntimeError.self) { try StateRoot.open(link, create: false) }
        #expect(try StateRoot.open(path.appending("missing"), create: false) == nil)
        _ = unsafe link.withPlatformString { unsafe unlink($0) }
        _ = unsafe shared.withPlatformString { unsafe rmdir($0) }
    }
}

@Test func verificationRequiresMatchingIdentity() throws {
    let parentPID = getppid()
    try #require(parentPID > 1, "The test runner needs a parent other than PID 1")
    let identity = try ProcFS.identity(of: parentPID)
    #expect(try ProcessHandle.withVerified(identity, separatePIDNamespace: false) { $0.pid } == parentPID)
    // A reused PID shows a different start time.
    var reused = identity
    reused.startTime += 1
    #expect(try ProcessHandle.withVerified(reused, separatePIDNamespace: false) { $0.pid } == nil)
    // A start time from another boot.
    var otherBoot = identity
    otherBoot.bootID = "00000000-0000-0000-0000-000000000000"
    #expect(try ProcessHandle.withVerified(otherBoot, separatePIDNamespace: false) { $0.pid } == nil)
    // A container with its own PID namespace never names a process in ours.
    #expect(try ProcessHandle.withVerified(identity, separatePIDNamespace: true) { $0.pid } == nil)
    // Nor PID 1 or this process, whatever the record says.
    let own = try ProcFS.identity(of: getpid())
    #expect(try ProcessHandle.withVerified(own, separatePIDNamespace: false) { $0.pid } == nil)
    let initIdentity = InitIdentity(pid: 1, startTime: identity.startTime, bootID: identity.bootID)
    #expect(try ProcessHandle.withVerified(initIdentity, separatePIDNamespace: false) { $0.pid } == nil)
}
#endif
