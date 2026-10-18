#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import LinuxAPI
import SystemPackage

extension OCIRunPlan.Namespace {
    var cloneFlag: Int32 {
        switch self {
        case .pid: Int32(CLONE_NEWPID)
        case .mount: Int32(CLONE_NEWNS)
        case .uts: Int32(CLONE_NEWUTS)
        case .ipc: Int32(CLONE_NEWIPC)
        case .network: Int32(CLONE_NEWNET)
        }
    }
}

extension OCIRunPlan.MountFlags {
    var kernelFlags: UInt {
        var flags: UInt = 0
        if contains(.nosuid) { flags |= UInt(MS_NOSUID) }
        if contains(.nodev) { flags |= UInt(MS_NODEV) }
        if contains(.noexec) { flags |= UInt(MS_NOEXEC) }
        if contains(.strictatime) { flags |= UInt(MS_STRICTATIME) }
        return flags
    }
}

extension OCIRunPlan {
    /// Launches the container. Without a gate the init executes the workload
    /// after setup and this returns its status. With a gate (and detached
    /// hooks) the init waits for `start` instead, and this returns 0 once it
    /// has been committed. With `pidfdSocket`, the init sends its own pidfd,
    /// labelled `standard`, before it drops privileges or reports readiness.
    func runOnLinux(hooks: LaunchHooks = LaunchHooks(), gate: StartGate? = nil, pidfdSocket: PidfdSocket? = nil) throws -> Int32 {
        var groups: [[String]] = [
            arguments,
            environment,
            [rootfs.string],
            hostname.map { [$0] } ?? [],
            cwd.indices.map { "/" + cwd[...$0].joined(separator: "/") },
            ["dev"],
            executable.candidates,
        ]
        for mount in mounts {
            groups.append(mount.destination)
            groups.append([mount.source, mount.type.rawValue, mount.data])
        }
        var strings = try CStringVector(groups: groups)
        let starts = strings.groupStarts
        let flags = namespaces.reduce(Int32(0)) { $0 | $1.cloneFlag }
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
        let pathControls = self.pathControls
        let cwdCount = cwd.count
        let lastCapability = try capabilities?.validatedKernelLimit() ?? -1
        let context: (LaunchStage, Int32) -> String? = { stage, detail in
            switch stage {
            case .resolveMount, .mount:
                guard mounts.indices.contains(Int(detail)) else { return nil }
                return "\(stage.description) \(mounts[Int(detail)].destinationPath)"
            case .findExecutable, .relativeExecutable: return "process.args[0] \(name): \(stage.description)"
            case .setUserID: return "\(stage.description) \(security.uid)"
            case .setGroupID: return "\(stage.description) \(security.gid)"
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
        let firstInternal = hooks.preserved.closeRangeStart
        return unsafe try strings.withPointers { pointers in
            try supplementaryGids.withUnsafeBufferPointer { gidBuffer in
                let root = unsafe RootFilesystemSetup(
                    strings: pointers, starts: starts, mounts: mounts, populatesDev: populatesDev,
                    readonlyRoot: readonlyRoot, pathControls: pathControls)
                let workload = unsafe WorkloadSetup(
                    argv: pointers + starts[InitStringGroup.arguments], environment: pointers + starts[InitStringGroup.environment],
                    executables: pointers + starts[InitStringGroup.executable], searchesPath: searchesPath,
                    directory: (pointers + starts[InitStringGroup.cwdPrefixes])[max(0, cwdCount - 1)],
                    security: security, supplementaryGids: gidBuffer, capabilities: capabilities,
                    lastCapability: lastCapability, resourceLimits: resourceLimits, foreground: !hooks.detached)
                return unsafe try NamespaceLauncher.run(namespaceFlags: flags, hooks: hooks, context: context) { report, commit, launcher in
                    // Preserve caller descriptors before any rootfs setup opens temporary handles.
                    guard linux_mark_descriptors_cloexec(firstInternal) == 0 else {
                        return LaunchRecord.reportFailure(to: report, at: .markDescriptors)
                    }
                    if let status = unsafe root.prepare(report: report) { return status }
                    // Init hands off its pidfd inside the root, before credentials and readiness.
                    if let failure = pidfdSocket?.handOff(label: .standard) { return LaunchRecord.reportFailure(to: report, failure) }
                    return unsafe workload.run(report: report, commit: commit, launcher: launcher, gate: gate)
                }
            }
        }
    }
}

#endif
