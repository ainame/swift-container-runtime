import SystemPackage

/// One hook's C buffers. The init's container-namespace hooks point into the
/// launch string vector prepared before fork; runtime-namespace hooks build
/// theirs just before running. Either way they outlive `HookRunner.run`.
@unsafe
struct PreparedHook {
    let path: UnsafePointer<CChar>
    /// argv, including argv[0]: the hook's `args`, or just its path.
    let arguments: UnsafePointer<UnsafeMutablePointer<CChar>?>
    /// nil inherits the running process's environment, as Go's exec does in runc.
    let environment: UnsafePointer<UnsafeMutablePointer<CChar>?>?
    let timeout: Duration?
}

/// How one hook ended.
enum HookOutcome: Equatable, Sendable {
    case success
    case spawnFailed(Errno)
    case exited(Int32)
    case signaled(Int32)
    case timedOut(seconds: Int64)

    /// runc's wording for a failed hook.
    var reason: String {
        switch self {
        case .success: "success"
        case let .spawnFailed(error): "\(error)"
        case let .exited(code): "exit status \(code)"
        case let .signaled(signal): "signal: \(Self.goSignalNames[signal] ?? "signal \(signal)")"
        case let .timedOut(seconds): "timeout after \(seconds)s"
        }
    }

    /// Go's names for the signals a failed hook commonly dies from.
    private static let goSignalNames: [Int32: String] = [
        1: "hangup", 2: "interrupt", 3: "quit", 6: "aborted", 9: "killed", 11: "segmentation fault",
        13: "broken pipe", 15: "terminated",
    ]
}

extension HookOutcome {
    /// A failed container-namespace hook as a launch failure: the index and
    /// outcome packed into `detail` (index | kind << 8 | value << 16), a spawn
    /// error in the errno field.
    func failure(at stage: LaunchStage, index: Int) -> LaunchFailure {
        let (kind, value): (Int32, Int32) = switch self {
        case .success, .spawnFailed: (4, 0)
        case let .exited(code): (1, code)
        case let .signaled(signal): (2, signal)
        case let .timedOut(seconds): (3, Int32(clamping: min(seconds, 32_767)))
        }
        let error: Errno? = if case let .spawnFailed(error) = self { error } else { nil }
        return LaunchFailure(stage: stage, error: error, detail: Int32(index) | kind << 8 | value << 16)
    }

    /// The hook index and outcome a launch failure's detail and errno carry.
    static func unpack(detail: Int32, error: Errno?) -> (index: Int, outcome: HookOutcome) {
        let value = detail >> 16
        let outcome: HookOutcome = switch (detail >> 8) & 0xff {
        case 1: .exited(value)
        case 2: .signaled(value)
        case 3: .timedOut(seconds: Int64(value))
        default: .spawnFailed(error ?? .ioError)
        }
        return (Int(detail & 0xff), outcome)
    }
}

/// Runs OCI hooks: the state JSON on stdin, output collected, an optional
/// timeout that kills the hook. Shared by the supervisor (prestart,
/// createRuntime, poststart, poststop) and the init (createContainer,
/// startContainer), so it uses only posix_spawn, poll and waitpid on stack
/// buffers and starts no threads.
enum HookRunner {
    /// Runs `hook` to completion. `writeState` writes the state JSON to the
    /// hook's stdin socket; `consume` receives each chunk of combined stdout
    /// and stderr. A hook that exits while a descendant keeps its output open
    /// is not waited for beyond its own exit.
    @unsafe
    static func run(
        _ hook: PreparedHook, writeState: (FileDescriptor) -> Void, consume: (RawSpan) -> Void = { _ in }
    ) -> HookOutcome {
        // Stdin is a socket so an early exit cannot raise SIGPIPE here (sends
        // use MSG_NOSIGNAL); output is a pipe read until EOF or exit.
        let input: (parent: FileDescriptor, child: FileDescriptor)
        let output: (readEnd: FileDescriptor, writeEnd: FileDescriptor)
        do {
            let pair = try Kernel.Socket.unixStreamPair()
            input = (pair.0, pair.1)
        } catch {
            return .spawnFailed(error)
        }
        var inputParent = OwnedFileDescriptor(takingOwnershipOf: input.parent)
        var inputChild = OwnedFileDescriptor(takingOwnershipOf: input.child)
        do {
            output = try FileDescriptor.pipe(options: .closeOnExec)
        } catch {
            return .spawnFailed(error)
        }
        let outputRead = OwnedFileDescriptor(takingOwnershipOf: output.readEnd)
        var outputWrite = OwnedFileDescriptor(takingOwnershipOf: output.writeEnd)

        let pid: pid_t
        do {
            pid = try unsafe Kernel.Process.spawnHook(
                hook.path, arguments: hook.arguments, environment: hook.environment, input: input.child, output: output.writeEnd)
        } catch {
            return .spawnFailed(error)
        }
        try? inputChild.close()
        try? outputWrite.close()
        writeState(input.parent)
        try? inputParent.close()

        // Collect output until EOF or exit, within the deadline.
        let clock = ContinuousClock()
        let deadline = unsafe hook.timeout.map { clock.now + $0 }
        var status: Int32? = nil
        var open = true
        while status == nil {
            if let deadline = deadline, clock.now >= deadline {
                try? Kernel.Process.signal(pid, Kernel.Signal.kill)
                _ = try? Kernel.Process.wait(pid)
                return .timedOut(seconds: unsafe hook.timeout.map { $0.components.seconds } ?? 0)
            }
            if open {
                let slice = deadline.map { min(clock.now.duration(to: $0), .milliseconds(50)) } ?? .milliseconds(50)
                if !outputRead.poll(.input, timeout: slice).isEmpty {
                    open = drain(outputRead, consume: consume)
                }
            } else {
                Kernel.Process.sleep(for: .milliseconds(10))
            }
            status = try? Kernel.Process.reapIfExited(pid)
        }
        // Whatever the exited hook already wrote, without waiting for descendants.
        while !outputRead.poll(.input, timeout: .zero).isDisjoint(with: [.input]), drain(outputRead, consume: consume) {}
        guard let status else { return .spawnFailed(.noChildProcess) }
        if status & 0x7f == 0 {
            let code = (status >> 8) & 0xff
            return code == 0 ? .success : .exited(code)
        }
        return .signaled(status & 0x7f)
    }

    /// Reads one chunk; false at EOF or on an error.
    private static func drain(_ owner: borrowing OwnedFileDescriptor, consume: (RawSpan) -> Void) -> Bool {
        var buffer = InlineArray<4096, UInt8>(repeating: 0)
        let count = (try? owner.withDescriptor { descriptor in
            var span = buffer.mutableSpan
            return try Kernel.File.read(descriptor, into: &span)
        }) ?? 0
        guard count > 0 else { return false }
        consume(buffer.span.bytes.extracting(0..<count))
        return true
    }
}
