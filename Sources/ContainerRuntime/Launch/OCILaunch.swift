import SystemPackage

extension OCIRunPlan.MountFlags {
    var kernelFlags: MountFlags {
        var flags: MountFlags = []
        if contains(.nosuid) { flags.insert(.noSetUserID) }
        if contains(.nodev) { flags.insert(.noDevices) }
        if contains(.noexec) { flags.insert(.noExecute) }
        if contains(.strictatime) { flags.insert(.strictAccessTime) }
        if contains(.readonly) { flags.insert(.readOnly) }
        return flags
    }
}

extension OCIRunPlan {
    /// Launches the container. Without a gate the init executes the workload
    /// after setup and this returns its status. With a gate (and detached
    /// hooks) the init waits for `start` instead, and this returns 0 once it
    /// has been committed. With `pidfdSocket`, the init sends its own pidfd,
    /// labelled `standard`, before it drops privileges or reports readiness.
    /// With `keyring`, the init joins the container's session keyring first.
    /// With `terminal`, it hands a new pseudoterminal to the console socket
    /// right after pivot_root, as runc does.
    func runOnLinux(
        hooks: LaunchHooks = LaunchHooks(), gate: StartGate? = nil, pidfdSocket: PidfdSocket? = nil,
        keyring: SessionKeyringSetup? = nil, terminal: TerminalSetup? = nil, hookSetup: InitHookSetup? = nil
    ) throws -> Int32 {
        var groups: [[String]] = [
            arguments,
            environment,
            [rootfs.string],
            hostname.map { [$0] } ?? [],
            cwd.indices.map { "/" + cwd[...$0].joined(separator: "/") },
            ["dev"],
            executable.candidates,
            sysctls.flatMap { [$0.path, $0.value] },
        ]
        for mount in mounts {
            groups.append(mount.destination)
            groups.append([mount.source, mount.type.kernelName, mount.data])
            groups.append(mount.type == .bind
                ? mount.destination.indices.map { "/" + mount.destination[...$0].joined(separator: "/") } : [])
        }
        // Custom device paths use the same pinned, component-wise walk as mounts.
        let deviceGroupBase = groups.count
        groups += devices.map(\.components)
        // Each container-namespace hook adds [path], its argv and its environment.
        let hookGroupBase = groups.count
        let createContainer = hookSetup?.hooks.createContainer ?? []
        let startContainer = hookSetup?.hooks.startContainer ?? []
        for hook in createContainer + startContainer {
            groups.append([hook.path])
            groups.append(hook.argv)
            groups.append(hook.env ?? [])
        }
        var strings = try CStringVector(groups: groups)
        let starts = strings.groupStarts
        let mounts = self.mounts
        let populatesDev = self.populatesDev
        let readonlyRoot = self.readonlyRoot
        let security = self.security
        let searchesPath = executable.searchesPath
        let name = arguments[0]
        // Converted before the fork so the init only borrows the buffer.
        let supplementaryGids = security.additionalGids.map { gid_t($0) }
        // Configured capabilities must exist in the running kernel, whose
        // whole range the init then clears from the bounding set.
        let capabilities = self.capabilities
        let resourceLimits = self.resourceLimits
        let filter = try seccomp.map(Kernel.Seccomp.compile)
        let labels = try SecurityLabelSetup(securityLabels)
        let oom = OOMScoreAdjustment(oomScoreAdjustment)
        let pathControls = self.pathControls
        let cwdCount = cwd.count
        let lastCapability = try capabilities?.validatedKernelLimit() ?? -1
        // Pin and validate in the supervisor. Only its forked launcher calls
        // setns, before unsharing the remaining namespaces or mounting sysfs.
        let namespaceHandles = try NamespaceHandle.joinOrder.compactMap { namespace in
            try namespacePaths[namespace].map { try NamespaceHandle(path: $0, namespace: namespace) }
        }
        let sysctls = self.sysctls
        // Host-owned namespaces may be explicitly joined, but their mutable
        // properties must never be changed as a side effect of this container.
        for handle in namespaceHandles where handle.matchesCaller {
            if handle.namespace == .mount {
                // pivot_root in the caller's namespace would detach its host
                // root. The omitted-mount path uses chroot plus recorded cleanup.
                throw RuntimeError("omit the mount namespace to inherit the caller's mounts safely")
            }
            if handle.namespace == .network, sysctls.contains(where: \.isNetwork) {
                throw RuntimeError("config.json: linux.sysctl net.* is not allowed in the host's network namespace")
            }
            if handle.namespace == .ipc, sysctls.contains(where: { !$0.isNetwork && $0.key != "kernel.domainname" }) {
                throw RuntimeError("config.json: linux.sysctl is not allowed in the host's ipc namespace")
            }
            if handle.namespace == .uts, hostname != nil || sysctls.contains(where: { $0.key == "kernel.domainname" }) {
                throw RuntimeError("config.json: hostname is not allowed in the host's uts namespace")
            }
        }
        let context: (LaunchStage, Int32) -> String? = { stage, detail in
            switch stage {
            case .sysctl:
                guard sysctls.indices.contains(Int(detail)) else { return nil }
                return "\(stage.description) \(sysctls[Int(detail)].key)"
            case .joinNamespaces:
                return networkNamespacePath.map { "join supplied network namespace \($0)" } ?? "join supplied namespace"
            case .openMountSource:
                guard mounts.indices.contains(Int(detail)) else { return nil }
                return "open bind mount source \(mounts[Int(detail)].source) for \(mounts[Int(detail)].destinationPath)"
            case .resolveMount, .mount:
                guard mounts.indices.contains(Int(detail)) else { return nil }
                return "\(stage.description) \(mounts[Int(detail)].destinationPath)"
            case .findExecutable, .relativeExecutable: return "process.args[0] \(name): \(stage.description)"
            case .setUserID: return "\(stage.description) \(security.uid)"
            case .setGroupID: return "\(stage.description) \(security.gid)"
            case .supplementaryGroups where detail == 1:
                return "\(stage.description): setgroups is denied in this user namespace (a rootless GID map written without newgidmap)"
            case .dropBoundingCapability:
                return "\(stage.description) \(CapabilitySet.name(of: Int(detail))) (the runtime needs CAP_SETPCAP)"
            case .raiseAmbientCapability:
                return "\(stage.description) \(CapabilitySet.name(of: Int(detail))) (refused by securebits or a missing permitted/inheritable capability)"
            case .setResourceLimit:
                guard resourceLimits.indices.contains(Int(detail)) else { return nil }
                return "\(stage.description)[\(detail)] \(resourceLimits[Int(detail)]) (raising a hard limit needs CAP_SYS_RESOURCE; RLIMIT_NOFILE cannot exceed fs.nr_open)"
            case .resolveReadonlyPath, .readonlyPath, .resolveMaskedPath, .maskPath, .verifyMaskedPath:
                let isMask = stage == .resolveMaskedPath || stage == .maskPath || stage == .verifyMaskedPath
                let paths = isMask ? pathControls.masked : pathControls.readonly
                guard paths.indices.contains(Int(detail)) else { return nil }
                return "\(stage.description) \(paths[Int(detail)])"
            default: return nil
            }
        }
        var launchHooks = hooks
        launchHooks.mapUserNamespace = userNamespace.map { mapping in { try mapping.install(for: $0) } }
        let firstInternal = hooks.preserved.closeRangeStart
        let createsCgroupNamespace = namespaces.contains(.cgroup)
        return unsafe try strings.withPointers { pointers in
            try supplementaryGids.withUnsafeBufferPointer { gidBuffer in
                var root = unsafe RootFilesystemSetup(
                    strings: pointers, starts: starts, mounts: mounts, devices: devices, deviceGroupBase: deviceGroupBase, bindsStandardDevices: userNamespace != nil || namespacePaths[.user] != nil, usesPivotRoot: usesPivotRoot, populatesDev: populatesDev,
                    readonlyRoot: readonlyRoot, rootPropagation: rootPropagation, pathControls: pathControls, terminal: terminal)
                // Hook buffers point into the launch strings, which outlive the launch.
                func prepared(_ hooks: [ContainerHooks.Hook], from first: Int, defaultEnvironment: UnsafePointer<UnsafeMutablePointer<CChar>?>?) -> [PreparedHook] {
                    unsafe hooks.enumerated().map { offset, hook in
                        let group = hookGroupBase + 3 * (first + offset)
                        return unsafe PreparedHook(
                            path: (pointers + starts[group])[0]!, arguments: pointers + starts[group + 1],
                            environment: hook.env == nil ? defaultEnvironment : pointers + starts[group + 2], timeout: hook.duration)
                    }
                }
                if let hookSetup {
                    unsafe root.runsRuntimeHooks = hookSetup.runsRuntimeHooks
                    unsafe root.createContainerHooks = unsafe InitHooks(
                        hooks: prepared(createContainer, from: 0, defaultEnvironment: nil),
                        state: hookSetup.creatingState, stage: .createContainerHook)
                }
                var workload = unsafe WorkloadSetup(
                    argv: pointers + starts[InitStringGroup.arguments], environment: pointers + starts[InitStringGroup.environment],
                    executables: pointers + starts[InitStringGroup.executable], searchesPath: searchesPath,
                    directory: (pointers + starts[InitStringGroup.cwdPrefixes])[max(0, cwdCount - 1)],
                    security: security, supplementaryGids: gidBuffer, capabilities: capabilities,
                    lastCapability: lastCapability, resourceLimits: resourceLimits, seccomp: filter, labels: labels, foreground: !hooks.detached)
                if let hookSetup {
                    // runc's default: startContainer hooks without env get the workload's.
                    unsafe workload.startContainerHooks = unsafe InitHooks(
                        hooks: prepared(startContainer, from: createContainer.count, defaultEnvironment: pointers + starts[InitStringGroup.environment]),
                        state: hookSetup.createdState, stage: .startContainerHook)
                }
                // The cgroup namespace is unshared by the init itself, below.
                return unsafe try NamespaceLauncher.run(unsharing: namespaces.filter { $0 != .cgroup }, hooks: launchHooks, context: context, prepareLauncher: {
                    if let failure = oom.apply() { return failure }
                    for handle in namespaceHandles {
                        if let error = handle.join() { return LaunchFailure(stage: .joinNamespaces, error: error) }
                    }
                    return nil
                }) { report, commit, launcher in
                    // Preserve caller descriptors before any rootfs setup opens temporary handles.
                    if let error = Errno.failure({ () throws(Errno) in try Kernel.Process.markDescriptorsCloseOnExec(from: firstInternal) }) {
                        return LaunchRecord.reportFailure(to: report, at: .markDescriptors, error: error)
                    }
                    // As runc: only after the supervisor placed the init in the
                    // container cgroup, so that cgroup becomes the namespace root.
                    if createsCgroupNamespace, let error = Errno.failure({ () throws(Errno) in
                        try Kernel.Namespace.unshare(OCIRunPlan.Namespace.cgroup.cloneFlag)
                    }) {
                        return LaunchRecord.reportFailure(to: report, at: .cgroupNamespace, error: error)
                    }
                    if let failure = keyring?.apply(labels: labels) { return LaunchRecord.reportFailure(to: report, failure) }
                    if let status = unsafe root.prepare(report: report, commit: commit) { return status }
                    // Init hands off its pidfd inside the root, before credentials and readiness.
                    if let failure = pidfdSocket?.handOff(label: .standard) { return LaunchRecord.reportFailure(to: report, failure) }
                    return unsafe workload.run(report: report, commit: commit, launcher: launcher, gate: gate)
                }
            }
        }
    }
}

