#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import LinuxAPI
import SystemPackage

extension OwnedFileDescriptor {
    /// Device and inode numbers of an owned descriptor, or nil if fstat fails.
    func identity() -> (device: dev_t, inode: ino_t)? {
        try? withDescriptor { descriptor -> (device: dev_t, inode: ino_t)? in
            var status = stat()
            guard unsafe fstat(descriptor.rawValue, &status) == 0 else { return nil }
            return (status.st_dev, status.st_ino)
        }
    }

    /// Names in a directory other than `.` and `..`.
    func directoryEntries() throws -> [String] {
        let raw = try withDescriptor { unsafe linux_open_at($0.rawValue, ".", O_RDONLY | O_DIRECTORY, 0) }
        guard raw >= 0 else { throw RuntimeError.system("list state directory") }
        // fdopendir takes ownership of the new descriptor; closedir closes it.
        guard let stream = unsafe fdopendir(raw) else {
            let error = Errno.current
            _ = LinuxAPI.close(raw)
            throw RuntimeError.system("list state directory", error)
        }
        defer { _ = unsafe closedir(stream) }
        var names: [String] = []
        while true {
            // readdir signals an error only through errno, and the String work
            // below may change errno, so clear it before every call.
            errno = 0
            guard let entry = unsafe readdir(stream) else {
                guard errno == 0 else { throw RuntimeError.system("list state directory") }
                return names
            }
            let name = unsafe withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                unsafe String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
    }

    /// Polls with a monotonic deadline, so interruption cannot restart the full
    /// timeout. A zero result means timeout or an invalid/unusable descriptor.
    func poll(events: Int16, timeout: Duration) -> Int16 {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        // Keep ownership through every retry and recompute only the remaining wait.
        return (try? withDescriptor { descriptor -> Int16 in
            while true {
                var target = pollfd(fd: descriptor.rawValue, events: events, revents: 0)
                let result = unsafe LinuxAPI.poll(&target, 1, clock.now.duration(to: deadline).pollTimeout)
                if result > 0 { return target.revents & Int16(POLLNVAL) == 0 ? target.revents : 0 }
                if result == 0 || errno != EINTR { return 0 }
                guard clock.now < deadline else { return 0 }
            }
        }) ?? 0
    }
}

extension Duration {
    /// poll(2)'s timeout in milliseconds: rounded up so a wakeup is never
    /// early, zero for a past deadline, and capped at the Int32 range.
    var pollTimeout: Int32 {
        guard self > .zero else { return 0 }
        let (seconds, attoseconds) = components
        guard seconds < Int64(Int32.max / 1000) + 1 else { return .max }
        return Int32(clamping: seconds * 1000 + (attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000)
    }
}
#endif
