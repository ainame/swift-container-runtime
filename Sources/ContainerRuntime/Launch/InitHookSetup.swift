import SystemPackage

/// Hooks the launch handles: whether prestart/createRuntime need the
/// handshake, and the container-namespace hooks (createContainer,
/// startContainer) with their state JSON. The supervisor prepares it before
/// fork; `runOnLinux` adds the hook strings to the launch string vector, so
/// the init only borrows prepared buffers.
struct InitHookSetup: Sendable {
    let hooks: ContainerHooks
    /// createContainer state (`creating`) without `pid`, which the init adds.
    let creatingState: [UInt8]
    /// startContainer state (`created`, as in runc) without `pid`.
    let createdState: [UInt8]

    /// The init pauses after its mounts for the runtime-namespace hooks.
    var runsRuntimeHooks: Bool { !hooks.prestart.isEmpty || !hooks.createRuntime.isEmpty }

    init(hooks: ContainerHooks, id: ContainerID, plan: OCIRunPlan) throws {
        self.hooks = hooks
        func state(_ status: HookState.Status) throws -> [UInt8] {
            try HookState(
                ociVersion: plan.ociVersion, id: id.rawValue, status: status, pid: nil,
                bundle: plan.bundle.string, annotations: plan.annotations
            ).encoded()
        }
        creatingState = try state(.creating)
        createdState = try state(.created)
    }

    private static let pidPrefix: [UInt8] = Array("{\"pid\":".utf8)
    private static let comma: [UInt8] = [UInt8(ascii: ",")]

    /// Sends `{"pid":<pid>,` and then `state` after its opening brace, so the
    /// child adds its own PID without building a string. `state` always
    /// holds at least the ID, so the comma joins two members.
    static func writeState(_ state: [UInt8], pid: pid_t, send: (RawSpan) -> Bool) {
        var digits = InlineArray<12, UInt8>(repeating: 0)
        var start = 12
        var value = Int64(pid)
        repeat {
            start -= 1
            digits[start] = UInt8(ascii: "0") + UInt8(value % 10)
            value /= 10
        } while value > 0
        guard send(pidPrefix.span.bytes), send(digits.span.bytes.extracting(start...)), send(comma.span.bytes) else { return }
        _ = send(state.span.bytes.extracting(1...))
    }
}

/// Prepared container-namespace hooks of one phase, pointing into the launch
/// string vector, with the state the init completes.
@unsafe
struct InitHooks {
    let hooks: [PreparedHook]
    let state: [UInt8]
    let stage: LaunchStage

    static var none: InitHooks { unsafe InitHooks(hooks: [], state: [], stage: .createContainerHook) }

    /// Runs every hook in order, inside the container's namespaces, with this
    /// process's PID in the state. Returns nil or the first failure.
    @unsafe
    func run() -> LaunchFailure? {
        let pid = Kernel.Process.id
        for unsafe (index, hook) in unsafe hooks.enumerated() {
            let outcome = unsafe HookRunner.run(hook, writeState: { unsafe InitHookSetup.writeState(state, pid: pid, send: $0) })
            if outcome != .success { return unsafe outcome.failure(at: stage, index: index) }
        }
        return nil
    }
}
