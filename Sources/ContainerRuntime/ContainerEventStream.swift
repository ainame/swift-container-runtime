#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import LinuxAPI
import SystemPackage

extension ContainerLifecycle {
    /// runc's `events`, with no lock held: a snapshot pins the container
    /// directory and its recorded cgroup generation, and the stream then
    /// observes only that pinned generation.
    func eventsOnLinux(id: ContainerID, interval: Int64, statsOnly: Bool, emit: (ContainerEvent) throws -> Void) throws {
        // runc checks that the container exists, then the interval, then
        // that it is not stopped.
        guard let root = try StateRoot.open(root, create: false) else { throw LifecycleError.notFound(id) }
        let directory = try root.openContainer(id)
        guard interval > 0 else { throw RuntimeError("duration interval must be greater than 0") }
        let record = try loadRecord(directory, id: id)
        guard try containerStatus(record: record, directory: directory, lockHeldByCaller: false) != .stopped else {
            throw RuntimeError("container with id \(id.rawValue) is not running")
        }
        guard let identity = record?.cgroup else { throw RuntimeError("container has no recorded cgroup") }

        if statsOnly {
            // As in runc, a failed snapshot is the command's error.
            try emit(.stats(try CgroupLeaf.stats(identity)))
            return
        }
        guard let source = try CgroupLeaf.eventSource(identity) else {
            throw RuntimeError("container's recorded cgroup is missing, replaced, or from another boot")
        }
        let stream = try EventWatch.make(root: root, directory: directory, source: source)
        try stream.run(id: id, identity: identity, interval: interval, emit: emit)
    }
}

/// The wakeups of one event stream. inotify(7) reports memory.events
/// changes (OOM kills) and cgroup.events changes (the cgroup emptying)
/// as runc's notifier does, plus entry changes in the state root and the
/// container directory, so deletion and recreation are seen promptly. A
/// synchronous poll(2) on it doubles as the stats timer; the root command
/// stays synchronous so the fork-based launcher is never mixed with an
/// async runtime. Events are only wakeups: the state is re-read each time,
/// so a coalesced or overflowed inotify queue loses nothing.
private struct EventWatch: ~Copyable {
    private let inotify: OwnedFileDescriptor
    private let root: StateRoot
    private let directory: OwnedFileDescriptor
    private let source: CgroupEventSource
    /// False without memory.events at startup, that is, without the memory
    /// controller; run adds the watch if the controller appears later.
    private let watchesOOM: Bool
    /// The oom_kill count read before memory.events was watched, or 0.
    private let initialOOMKills: UInt64

    /// Receives only ready owners, so every stored property is initialized
    /// on the single path through it and nothing is partially owned.
    private init(
        inotify: consuming OwnedFileDescriptor, root: StateRoot, directory: consuming OwnedFileDescriptor,
        source: CgroupEventSource, watchesOOM: Bool, initialOOMKills: UInt64
    ) {
        self.inotify = inotify
        self.root = root
        self.directory = directory
        self.source = source
        self.watchesOOM = watchesOOM
        self.initialOOMKills = initialOOMKills
    }

    /// Creates the inotify instance and its watches. A failure destroys the
    /// local owners, closing both descriptors, before anything is stored.
    static func make(root: StateRoot, directory: consuming OwnedFileDescriptor, source: CgroupEventSource) throws -> EventWatch {
        // O_NONBLOCK and O_CLOEXEC share IN_NONBLOCK and IN_CLOEXEC's values,
        // which libc headers declare with differing C types.
        let raw = inotify_init1(O_NONBLOCK | O_CLOEXEC)
        guard raw >= 0 else { throw RuntimeError("inotify_init1: \(Errno(rawValue: errno))") }
        let inotify = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))

        // Watches go through /proc/self/fd paths of the pinned descriptors.
        let modified = UInt32(IN_MODIFY)
        let entries = UInt32(IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR)
        // The baseline is read before the watch exists: kills before it are
        // not replayed, and one during setup leaves the count above the
        // baseline, so run's first read reports it even without a wakeup.
        let initialOOMKills = source.oomKillCount() ?? 0
        let watchesOOM = try watch(inotify, source.watchPath("memory.events"), modified, optional: true)
        _ = try watch(inotify, source.watchPath("cgroup.events"), modified, optional: false)
        let rootPath = try root.descriptor.withDescriptor { "/proc/self/fd/\($0.rawValue)" }
        _ = try watch(inotify, rootPath, entries, optional: false)
        let directoryPath = try directory.withDescriptor { "/proc/self/fd/\($0.rawValue)" }
        _ = try watch(inotify, directoryPath, entries, optional: false)

        return EventWatch(
            inotify: inotify, root: root, directory: directory,
            source: source, watchesOOM: watchesOOM, initialOOMKills: initialOOMKills
        )
    }

    /// Adds a watch through a /proc/self/fd path, which resolves to the
    /// pinned file rather than whatever the original path names now.
    /// Returns false when an optional file does not exist.
    private static func watch(_ inotify: borrowing OwnedFileDescriptor, _ path: String, _ mask: UInt32, optional: Bool) throws -> Bool {
        let result = try inotify.withDescriptor { unsafe inotify_add_watch($0.rawValue, path, mask) }
        if result >= 0 { return true }
        let code = errno
        if optional && code == ENOENT { return false }
        throw RuntimeError("unable to add inotify watch for \(path): \(Errno(rawValue: code))")
    }

    /// Emits OOM events as they happen and statistics every `interval`
    /// nanoseconds, the first one interval after the start, as runc's
    /// ticker does. Ends when the cgroup empties, cannot be read, or the
    /// container's state is deleted or replaced by a new generation.
    func run(id: ContainerID, identity: CgroupIdentity, interval: Int64, emit: (ContainerEvent) throws -> Void) throws {
        // Kills counted before the watch began are not reported. runc
        // reports any memory.events change once oom_kill is nonzero; this
        // reports each increase instead, so unrelated memory.events updates
        // (high/max throttling) do not repeat an old kill.
        var oomKills = initialOOMKills
        var watchingOOM = watchesOOM
        // Ticks are offsets from the start, in nanoseconds.
        let clock = ContinuousClock()
        let start = clock.now
        var tick = interval
        while true {
            // An update may enable the memory controller later, in the pinned
            // directory. Its watch is added before the count is read, against
            // the baseline of 0 kept for the absent counter, so a kill during
            // activation is still reported.
            if !watchingOOM {
                watchingOOM = try Self.watch(inotify, source.watchPath("memory.events"), UInt32(IN_MODIFY), optional: true)
            }
            if watchingOOM, let count = source.oomKillCount(), count > oomKills {
                oomKills = count
                try emit(.oom)
            }
            if try ended(id: id, identity: identity) { return }
            if EventSchedule.nanoseconds(start.duration(to: clock.now)) >= tick {
                // As in runc, a failed sample is reported and the stream goes
                // on; a failed write of an event ends the command.
                let stats: ContainerStats?
                do {
                    stats = try source.stats()
                } catch {
                    RuntimeDiagnostics.writeError("swift-container-runtime: error: \(error)")
                    stats = nil
                }
                if let stats { try emit(.stats(stats)) }
                // Ticks missed while busy are dropped, like Go's time.Ticker,
                // computed from one clock reading so even a 1ns interval
                // cannot chase the advancing clock.
                tick = EventSchedule.next(after: EventSchedule.nanoseconds(start.duration(to: clock.now)), interval: interval)
            }
            // Enabling a controller creates files without any watched event
            // (a rejected update may not rewrite state), so until memory.events
            // exists it is rescanned every 100ms; stats deadlines are unchanged.
            var timeout = Self.milliseconds(until: start + .nanoseconds(tick), clock: clock)
            if !watchingOOM { timeout = min(timeout, 100) }
            try waitForChange(milliseconds: timeout)
        }
    }

    private func ended(id: ContainerID, identity: CgroupIdentity) throws -> Bool {
        guard source.isPopulated() else { return true }
        guard try root.contains(directory, as: id) else { return true }
        // state.json is replaced atomically by updates, which keep the
        // cgroup generation; only a missing or different one ends the stream.
        return try loadRecord(directory, id: id)?.cgroup != identity
    }

    /// Waits for an inotify event or the timeout, then drains the queue.
    private func waitForChange(milliseconds: Int32) throws {
        try inotify.withDescriptor { descriptor in
            var target = pollfd(fd: descriptor.rawValue, events: Int16(POLLIN), revents: 0)
            let result = unsafe poll(&target, 1, milliseconds)
            if result < 0 {
                guard errno == EINTR else { throw RuntimeError("poll inotify: \(Errno(rawValue: errno))") }
                return
            }
            guard result > 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                do {
                    let count = try buffer.withUnsafeMutableBytes { bytes in unsafe try descriptor.read(into: bytes) }
                    if count == 0 { return }
                } catch let error as Errno where error == .interrupted {
                    continue
                } catch let error as Errno where error == .resourceTemporarilyUnavailable {
                    return
                }
            }
        }
    }

    /// poll(2)'s timeout: the time left, rounded up so a wakeup is never
    /// early, and capped at its Int32 range.
    private static func milliseconds(until deadline: ContinuousClock.Instant, clock: ContinuousClock) -> Int32 {
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { return 0 }
        let (seconds, attoseconds) = remaining.components
        let total = seconds * 1000 + (attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
        return Int32(clamping: total)
    }
}
#endif
