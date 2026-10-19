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
    /// A hook's transport failed while the runner still owned its child.
    case ioFailed(Errno)
    /// waitpid failed; the runner must not treat this as a still-running hook.
    case waitFailed(Errno)
    case exited(Int32)
    case signaled(Int32)
    case timedOut(seconds: Int64)

    /// runc's wording for a failed hook.
    var reason: String {
        switch self {
        case .success: "success"
        case let .spawnFailed(error): "\(error)"
        case let .ioFailed(error): "hook I/O: \(error)"
        case let .waitFailed(error): "wait for hook: \(error)"
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
    /// or I/O/wait error in the errno field.
    func failure(at stage: LaunchStage, index: Int) -> LaunchFailure {
        let (kind, value): (Int32, Int32) = switch self {
        case .success, .spawnFailed: (4, 0)
        case .ioFailed: (5, 0)
        case .waitFailed: (6, 0)
        case let .exited(code): (1, code)
        case let .signaled(signal): (2, signal)
        case let .timedOut(seconds): (3, Int32(clamping: min(seconds, 32_767)))
        }
        let error: Errno?
        switch self {
        case let .spawnFailed(value), let .ioFailed(value), let .waitFailed(value): error = value
        default: error = nil
        }
        return LaunchFailure(stage: stage, error: error, detail: Int32(index) | kind << 8 | value << 16)
    }

    /// The hook index and outcome a launch failure's detail and errno carry.
    static func unpack(detail: Int32, error: Errno?) -> (index: Int, outcome: HookOutcome) {
        let value = detail >> 16
        let outcome: HookOutcome = switch (detail >> 8) & 0xff {
        case 1: .exited(value)
        case 2: .signaled(value)
        case 3: .timedOut(seconds: Int64(value))
        case 5: .ioFailed(error ?? .ioError)
        case 6: .waitFailed(error ?? .noChildProcess)
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
    /// Runs `hook` to completion. `writeState` submits prepared JSON fragments
    /// through a deadline-aware sender and must stop when it returns false.
    /// `consume` receives combined stdout/stderr. Input delivery and output
    /// draining share the hook deadline; descendants cannot prolong final drain.
    @unsafe
    static func run(
        _ hook: PreparedHook, writeState: (_ send: (RawSpan) -> Bool) -> Void,
        consume: (RawSpan) -> Void = { _ in }
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

        let clock = ContinuousClock()
        let deadline = unsafe hook.timeout.map { clock.now + $0 }
        let pid: pid_t
        do {
            pid = try unsafe Kernel.Process.spawnHook(
                hook.path, arguments: hook.arguments, environment: hook.environment, input: input.child, output: output.writeEnd)
        } catch {
            return .spawnFailed(error)
        }
        try? inputChild.close()
        try? outputWrite.close()
        var progress = HookProgress(pid: pid, deadline: deadline, timeout: unsafe hook.timeout)
        // The output consumer is invoked synchronously while the state writer
        // waits for space. Neither callback escapes this scope; the temporary
        // conversion permits that nesting without storing either closure.
        withoutActuallyEscaping(consume) { consume in
            writeState { bytes in
                progress.send(bytes, to: input.parent, reading: output.readEnd, consume: consume)
            }
        }
        try? inputParent.close()

        // Closing stdin after the fragments gives the hook EOF even when it
        // chose not to consume the entire state. Keep draining while it runs.
        while progress.check() {
            progress.poll(reading: output.readEnd, writing: nil, consume: consume)
        }

        // Retain available diagnostics, not a descendant's unbounded output.
        // The diagnostic consumer already retains at most 64 KiB; a matching
        // byte budget and a short deadline also bound continuously ready pipes.
        let drainDeadline = min(deadline ?? (clock.now + .milliseconds(100)), clock.now + .milliseconds(100))
        // Sixteen reads of at most 4 KiB also bound small, continuous writes.
        var remainingChunks = 16
        while remainingChunks > 0, clock.now < drainDeadline,
              outputRead.poll(.input, timeout: .zero).contains(.input) {
            guard let count = try? drain(output.readEnd, consume: consume), count > 0 else { break }
            remainingChunks -= 1
        }
        return progress.outcome ?? .waitFailed(.noChildProcess)
    }

    /// Reads one ready chunk, returning zero at EOF. The caller owns the only
    /// reader, so readiness cannot be consumed between its poll and this read.
    fileprivate static func drain(_ descriptor: FileDescriptor, consume: (RawSpan) -> Void) throws(Errno) -> Int {
        var buffer = InlineArray<4096, UInt8>(repeating: 0)
        var span = buffer.mutableSpan
        let count = try Kernel.File.read(descriptor, into: &span)
        guard count > 0 else { return 0 }
        consume(buffer.span.bytes.extracting(0..<count))
        return count
    }
}

/// Synchronous progress for one spawned hook, in either the supervisor or init.
/// Only this runner waits for `pid`; an unreaped child keeps its PID reserved.
/// Descriptors passed to its methods remain owned by `HookRunner.run`.
private struct HookProgress {
    let pid: pid_t
    let deadline: ContinuousClock.Instant?
    let timeout: Duration?
    var outcome: HookOutcome?
    var outputOpen = true

    /// Observes exit before enforcing the deadline. Wait errors terminate the
    /// runner explicitly; ECHILD must never turn into an endless polling loop.
    mutating func check() -> Bool {
        guard outcome == nil else { return false }
        do {
            if let status = try Kernel.Process.reapIfExited(pid) {
                let signal = status & 0x7f
                let code = (status >> 8) & 0xff
                outcome = signal == 0 ? (code == 0 ? .success : .exited(code)) : .signaled(signal)
                return false
            }
        } catch {
            // Ownership is no longer established after a wait error: do not
            // signal a numeric PID that might already have been reaped/reused.
            outcome = .waitFailed(error)
            return false
        }
        if let deadline, ContinuousClock.now >= deadline {
            stop(with: .timedOut(seconds: timeout?.components.seconds ?? 0))
            return false
        }
        return true
    }

    /// Sends a fragment without blocking on a full stdin socket. When the
    /// hook writes before reading, drain output while waiting for input space.
    mutating func send(_ bytes: RawSpan, to input: FileDescriptor, reading output: FileDescriptor, consume: (RawSpan) -> Void) -> Bool {
        var sent = 0
        while sent < bytes.byteCount, check() {
            do {
                let count = try Kernel.Socket.send(input, bytes.extracting(sent...), nonBlocking: true)
                guard count > 0 else { return false }
                sent += count
            } catch .resourceTemporarilyUnavailable {
                poll(reading: output, writing: input, consume: consume)
            } catch .brokenPipe, .connectionReset {
                // A hook may close stdin intentionally. Its exit still decides
                // success/failure, rather than the remainder of its state JSON.
                return false
            } catch {
                stop(with: .ioFailed(error))
                return false
            }
        }
        return sent == bytes.byteCount
    }

    /// Waits on both I/O directions in bounded slices so waitpid and the shared
    /// deadline are checked even when a hook produces no output.
    mutating func poll(reading output: FileDescriptor, writing input: FileDescriptor?, consume: (RawSpan) -> Void) {
        guard outcome == nil else { return }
        let slice = deadline.map { min(ContinuousClock.now.duration(to: $0), .milliseconds(50)) } ?? .milliseconds(50)
        do {
            let events = try Kernel.Poll.wait(reading: outputOpen ? output : nil, writing: input, timeout: slice)
            if !events.read.isEmpty {
                outputOpen = try HookRunner.drain(output, consume: consume) > 0
            }
        } catch {
            stop(with: .ioFailed(error))
        }
    }

    /// Ends a hook after an I/O failure or timeout and reaps our still-owned
    /// child. Cleanup errors do not replace the original failure.
    private mutating func stop(with failure: HookOutcome) {
        try? Kernel.Process.signal(pid, Kernel.Signal.kill)
        _ = try? Kernel.Process.wait(pid)
        outcome = failure
    }
}
