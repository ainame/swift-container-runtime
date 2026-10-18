import SystemPackage

enum LaunchStage: Int32 {
    case pipe = 1, forkLauncher, namespaces, propagation, forkInit, procMount
    case hostname, execute, wait, protocolRead, parentLifetime, inspectThreads
    case bindRootfs, openRootfs, resolveMount, mount, devices, pivotRoot, cwd, verifyRootfs, markDescriptors
    case pinInit, commit, startRequest, startSocket, joinNamespaces, enterRoot
    case noNewPrivileges, stdioOwnership, supplementaryGroups, setGroupID, setUserID
    case dropBoundingCapability, keepCapabilities, setCapabilities, clearAmbientCapabilities, raiseAmbientCapability
    case setResourceLimit, startDescriptor, readonlyRoot
    case resolveReadonlyPath, readonlyPath, openDevNull, resolveMaskedPath, maskPath, verifyMaskedPath
    case findExecutable, relativeExecutable, pidfdOpen, pidfdSend

    var description: String {
        switch self {
        case .pipe: "create launch pipe"
        case .forkLauncher: "fork launcher"
        case .namespaces: "create namespaces"
        case .propagation: "make mount propagation private"
        case .forkInit: "fork namespace init"
        case .procMount: "mount proc"
        case .hostname: "set hostname"
        case .execute: "exec workload"
        case .wait: "wait for workload"
        case .protocolRead: "read launch result"
        case .parentLifetime: "protect parent lifetime"
        case .inspectThreads: "inspect launch threads"
        case .bindRootfs: "bind mount rootfs"
        case .openRootfs: "open rootfs"
        case .resolveMount: "resolve mount destination"
        case .mount: "mount"
        case .devices: "create /dev entries"
        case .pivotRoot: "pivot_root"
        case .cwd: "change to process.cwd"
        case .verifyRootfs: "verify rootfs was not replaced during setup"
        case .markDescriptors: "mark inherited descriptors close-on-exec (requires Linux 5.11+)"
        case .joinNamespaces: "join container namespaces"
        case .enterRoot: "enter container root"
        case .pinInit: "pin container init with a pidfd"
        case .commit: "release prepared container init"
        case .startRequest: "accept start request"
        case .startSocket: "consume start socket"
        case .noNewPrivileges: "set no_new_privs"
        case .stdioOwnership: "give stdio to process.user.uid"
        case .supplementaryGroups: "set process.user.additionalGids"
        case .setGroupID: "set process.user.gid"
        case .setUserID: "set process.user.uid"
        case .dropBoundingCapability: "drop bounding capability"
        case .keepCapabilities: "set PR_SET_KEEPCAPS"
        case .setCapabilities:
            "set effective, permitted, and inheritable capabilities (the runtime must hold every permitted one, and each inheritable one must be in bounding or already inheritable)"
        case .clearAmbientCapabilities: "clear ambient capabilities (requires Linux 4.3+)"
        case .raiseAmbientCapability: "raise ambient capability"
        case .setResourceLimit: "set process.rlimits"
        case .startDescriptor:
            "reserve a descriptor for the start connection (process.rlimits RLIMIT_NOFILE leaves no free descriptor for the created init)"
        case .readonlyRoot: "remount the container root read-only (root.readonly)"
        case .resolveReadonlyPath:
            "resolve linux.readonlyPaths entry in the container (symlinks stay within the root; magic links are refused)"
        case .readonlyPath: "make linux.readonlyPaths entry read-only (requires Linux 5.12+)"
        case .resolveMaskedPath:
            "resolve linux.maskedPaths entry in the container (symlinks stay within the root; magic links are refused)"
        case .openDevNull: "open the container's /dev/null for linux.maskedPaths (it must be the 1:3 character device)"
        case .maskPath: "mask linux.maskedPaths entry"
        case .verifyMaskedPath:
            "verify linux.maskedPaths entry shows its mask (a mask on / is hidden beneath the container root)"
        case .findExecutable: "executable file not found in the process PATH"
        case .relativeExecutable: "refusing an executable found through PATH relative to the current directory"
        case .pidfdOpen: "open a pidfd for --pidfd-socket (pidfd_open requires Linux 5.3+)"
        case .pidfdSend: "send the pidfd to --pidfd-socket"
        }
    }
}

/// Fixed-size records sent by forked copies of this executable over the
/// report pipe (or, for a start failure, the start connection). A record is
/// smaller than PIPE_BUF, so each pipe write is atomic. Both ends are the same
/// executable, so the encoding is a fixed little-endian layout of the fields.
struct LaunchRecord {
    enum Kind: Int32 {
        /// `accepted`: a created init took a start request and waits for
        /// the start command to commit it (see `StartGate`).
        case failure = 1, initProcess, ready, accepted
    }

    // Raw fields keep the wire layout fixed; use `error` for the errno.
    var kind: Int32 = 0
    var stage: Int32 = 0
    var code: Int32 = 0
    /// Stage-specific context, such as a mount index; -1 when unused.
    var detail: Int32 = -1
    /// The init PID in the supervisor's PID namespace, for `initProcess`.
    var value: Int64 = 0

    init() {}

    init(_ kind: Kind, stage: Int32 = 0, error: Errno? = nil, detail: Int32 = -1, value: Int64 = 0) {
        self.kind = kind.rawValue
        self.stage = stage
        self.code = error?.rawValue ?? 0
        self.detail = detail
        self.value = value
    }

    /// The reported errno, or nil for a failure without one.
    var error: Errno? { code == 0 ? nil : Errno(rawValue: code) }

    /// The encoded size: four 32-bit fields and one 64-bit field.
    static let byteCount = 24

    /// The fields in order, each little-endian.
    var bytes: [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.byteCount)
        func append<Field: FixedWidthInteger>(_ field: Field) {
            for shift in stride(from: 0, to: Field.bitWidth, by: 8) {
                bytes.append(UInt8(truncatingIfNeeded: field >> shift))
            }
        }
        append(kind); append(stage); append(code); append(detail); append(value)
        return bytes
    }

    /// Decodes `byteCount` bytes written by `bytes`.
    init(bytes: [UInt8]) {
        precondition(bytes.count == Self.byteCount)
        var offset = 0
        func next<Field: FixedWidthInteger>(_: Field.Type) -> Field {
            var field: Field = 0
            for index in 0..<(Field.bitWidth / 8) {
                field |= Field(truncatingIfNeeded: bytes[offset + index]) << (8 * index)
            }
            offset += Field.bitWidth / 8
            return field
        }
        kind = next(Int32.self)
        stage = next(Int32.self)
        code = next(Int32.self)
        detail = next(Int32.self)
        value = next(Int64.self)
    }
}

/// A child-side setup failure, reported through a `LaunchRecord` before exit.
struct LaunchFailure {
    let stage: LaunchStage
    /// Nil for a failure without an errno, such as a refused executable lookup.
    let error: Errno?
    /// Stage-specific context, such as a mount index; -1 when unused.
    var detail: Int32 = -1
}

enum RecordRead {
    case record(LaunchRecord)
    case end
    case failed(Errno)
}


/// Bytes the supervisor sends on the commit socket, in this order.
enum LaunchControl: UInt8 {
    /// A detached init may leave setup (see `LaunchControl.receive`).
    case commit = 1
    /// The init is in its cgroup and may start setup. On the release socket:
    /// the init is pinned and placed, so the launcher may continue.
    case proceed = 2
    /// Release socket only: the launch failed, so a detached launcher reaps
    /// its child instead of leaving it to the caller's subreaper.
    case abandon = 3
}

extension LaunchRecord {
    /// Writes one whole record and reports success. Socket writes use
    /// MSG_NOSIGNAL so a vanished peer cannot kill the writer with SIGPIPE.
    @discardableResult
    func write(to owner: borrowing OwnedFileDescriptor, socket: Bool = false) -> Bool {
        let bytes = self.bytes
        // Keep ownership through the write. A cached raw number alone could
        // outlive its owner on a child path that never returns to Swift.
        return (try? owner.withDescriptor { descriptor in
            // One write either way; a record is smaller than PIPE_BUF.
            let written = socket
                ? try Kernel.Socket.send(descriptor, bytes.span.bytes)
                : try Kernel.File.write(descriptor, bytes.span.bytes)
            return written == bytes.count
        }) ?? false
    }

    /// Reads one whole record, or reports EOF before its first byte.
    static func read(from owner: borrowing OwnedFileDescriptor) -> RecordRead {
        do {
            return try owner.withDescriptor { readEnd in
                var bytes: [UInt8] = []
                while bytes.count < byteCount {
                    let chunk = try Kernel.File.read(readEnd, upTo: byteCount - bytes.count)
                    if chunk.isEmpty { return bytes.isEmpty ? .end : .failed(.ioError) }
                    bytes += chunk
                }
                return .record(LaunchRecord(bytes: bytes))
            }
        } catch {
            return .failed((error as? Errno) ?? .ioError)
        }
    }

    /// Reports a child-side failure and returns the status to pass to `_exit`.
    /// Call as `_exit(LaunchRecord.reportFailure(...))` or return it from a launch body.
    static func reportFailure(
        to owner: borrowing OwnedFileDescriptor, at stage: LaunchStage, error: Errno? = .current, detail: Int32 = -1,
        socket: Bool = false
    ) -> Int32 {
        LaunchRecord(.failure, stage: stage.rawValue, error: error, detail: detail).write(to: owner, socket: socket)
        return 125
    }

    static func reportFailure(to owner: borrowing OwnedFileDescriptor, _ failure: LaunchFailure) -> Int32 {
        reportFailure(to: owner, at: failure.stage, error: failure.error, detail: failure.detail)
    }
}

extension LaunchControl {
    func send(over owner: borrowing OwnedFileDescriptor) throws {
        let sent: Int
        do {
            sent = try owner.withDescriptor { try Kernel.Socket.send($0, [rawValue].span.bytes) }
        } catch {
            throw RuntimeError.launch(.commit, (error as? Errno) ?? .badFileDescriptor)
        }
        guard sent == 1 else { throw RuntimeError.launch(.commit, .ioError) }
    }

    /// One control byte from the supervisor; nil on EOF or error.
    static func receive(from owner: borrowing OwnedFileDescriptor) -> LaunchControl? {
        let bytes = try? owner.withDescriptor { try Kernel.File.read($0, upTo: 1) }
        return bytes?.first.flatMap { LaunchControl(rawValue: $0) }
    }
}
