import SystemPackage

/// One owner for namespace and root descriptors opened while the recorded
/// init is pinned. Later PID reuse cannot redirect any of these handles.
struct ExecNamespaceSet: ~Copyable {
    let mount: OwnedFileDescriptor
    let pid: OwnedFileDescriptor
    let uts: OwnedFileDescriptor
    let ipc: OwnedFileDescriptor
    let network: OwnedFileDescriptor
    let root: OwnedFileDescriptor

    init(process: borrowing ProcessHandle) throws {
        let directory = OwnedFileDescriptor(takingOwnershipOf: try FileDescriptor.open(
            FilePath("/proc/\(process.pid)"), .readOnly, options: [.directory, .closeOnExec]))
        func open(_ path: String, root: Bool = false) throws -> OwnedFileDescriptor {
            do {
                // The root is only a chroot target, so an O_PATH handle suffices.
                return root
                    ? try Kernel.File.openPath(path, in: directory, options: .directory)
                    : try Kernel.File.open(path, in: directory, .readOnly)
            } catch {
                throw RuntimeError("open exec \(path): \(error)")
            }
        }
        // The proc directory and each namespace are pinned before checking
        // the pidfd again: an exit during acquisition invalidates this set.
        let mount = try open("ns/mnt")
        let pid = try open("ns/pid")
        let uts = try open("ns/uts")
        let ipc = try open("ns/ipc")
        let network = try open("ns/net")
        let root = try open("root", root: true)
        guard !process.waitForExit(timeout: .zero) else {
            throw RuntimeError("container init exited while opening exec namespaces")
        }
        // Complete every throwing operation before moving the owners into
        // self; partial noncopyable initialization is not supported yet.
        self.mount = consume mount
        self.pid = consume pid
        self.uts = consume uts
        self.ipc = consume ipc
        self.network = consume network
        self.root = consume root
    }

    /// Called only in the single-threaded launcher. PID namespace entry
    /// applies to the next fork; the launcher remains outside that namespace.
    func join() -> Errno? {
        func enter(_ owner: borrowing OwnedFileDescriptor, _ namespace: OCIRunPlan.Namespace) -> Errno? {
            owner.failure(in: { descriptor in Errno.failure { () throws(Errno) in try Kernel.Namespace.enter(descriptor, namespace) } })
        }
        if let error = enter(network, .network) { return error }
        if let error = enter(ipc, .ipc) { return error }
        if let error = enter(uts, .uts) { return error }
        if let error = enter(mount, .mount) { return error }
        return enter(pid, .pid)
    }

    /// Chroot through the live init's root descriptor, never its host path.
    /// No mount or propagation operation changes the existing container.
    func enterRoot() -> Errno? {
        if let error = root.failure(in: { root in
            Errno.failure { () throws(Errno) in try Kernel.Process.changeDirectory(to: root) }
        }) {
            return error
        }
        return Errno.failure { () throws(Errno) in
            try unsafe Kernel.Process.changeRoot(".")
            try unsafe Kernel.Process.changeDirectory("/")
        }
    }
}

extension OCIProcessPlan {
    /// The existing launch handshake pins and places the exec child before
    /// releasing it, and confirms exec by EOF on its close-on-exec pipe.
    /// With `pidfdSocket`, the process sends its own pidfd, labelled `setns`.
    func execOnLinux(namespaces: borrowing ExecNamespaceSet, hooks: LaunchHooks, pidfdSocket: PidfdSocket? = nil) throws -> Int32 {
        var strings = try CStringVector(
            groups: [arguments, environment, ["/" + cwd.joined(separator: "/")], executable.candidates]
        )
        let starts = strings.groupStarts
        let searchesPath = executable.searchesPath
        let name = arguments[0]
        let context: (LaunchStage, Int32) -> String? = { stage, _ in
            switch stage {
            case .findExecutable, .relativeExecutable: "process.args[0] \(name): \(stage.description)"
            default: nil
            }
        }
        let gids = security.additionalGids.map { gid_t($0) }
        let last = try capabilities?.validatedKernelLimit() ?? -1

        // All borrowed C storage spans the complete synchronous launch. The
        // original CLI never changes its own namespaces or root directory.
        let firstInternal = hooks.preserved.closeRangeStart
        return try gids.withUnsafeBufferPointer { groups in
            unsafe try strings.withPointers { pointers in
                let workload = unsafe WorkloadSetup(
                    argv: pointers + starts[0], environment: pointers + starts[1],
                    executables: pointers + starts[3], searchesPath: searchesPath,
                    directory: (pointers + starts[2])[0], security: security,
                    supplementaryGids: groups, capabilities: capabilities, lastCapability: last,
                    resourceLimits: resourceLimits, foreground: !hooks.detached)
                return unsafe try NamespaceLauncher.run(hooks: hooks, context: context, prepareLauncher: { namespaces.join() }) { report, commit, launcher in
                    if let error = Errno.failure({ () throws(Errno) in try Kernel.Process.markDescriptorsCloseOnExec(from: firstInternal) }) {
                        return LaunchRecord.reportFailure(to: report, at: .markDescriptors, error: error)
                    }
                    if let error = namespaces.enterRoot() { return LaunchRecord.reportFailure(to: report, at: .enterRoot, error: error) }
                    // As runc's setns init: inside the container, before
                    // no_new_privs and the credential switch.
                    if let failure = pidfdSocket?.handOff(label: .setns) { return LaunchRecord.reportFailure(to: report, failure) }
                    return unsafe workload.run(report: report, commit: commit, launcher: launcher, gate: nil)
                }
            }
        }
    }
}
