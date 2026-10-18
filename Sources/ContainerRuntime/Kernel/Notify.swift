#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
#if os(Linux)
import LinuxAPI
#endif
import SystemPackage

/// inotify(7) event bits, with the kernel's stable values so the set is
/// spelled the same on every platform.
struct NotifyEvents: OptionSet, Sendable {
    let rawValue: UInt32

    static let modified = NotifyEvents(rawValue: 0x0000_0002)
    static let movedFrom = NotifyEvents(rawValue: 0x0000_0040)
    static let movedTo = NotifyEvents(rawValue: 0x0000_0080)
    static let created = NotifyEvents(rawValue: 0x0000_0100)
    static let deleted = NotifyEvents(rawValue: 0x0000_0200)
    static let deletedSelf = NotifyEvents(rawValue: 0x0000_0400)
    static let movedSelf = NotifyEvents(rawValue: 0x0000_0800)
    /// Fails the watch unless the path is a directory.
    static let onlyDirectory = NotifyEvents(rawValue: 0x0100_0000)
}

extension Kernel {
    /// inotify, used only as a wakeup source: events are drained, not decoded.
    enum Notify {
        /// inotify_init1(IN_NONBLOCK | IN_CLOEXEC).
        static func open() throws(Errno) -> OwnedFileDescriptor {
            #if os(Linux)
            // IN_NONBLOCK and IN_CLOEXEC share O_NONBLOCK and O_CLOEXEC's values,
            // which libc headers declare with differing C types.
            let raw = inotify_init1(O_NONBLOCK | O_CLOEXEC)
            guard raw >= 0 else { throw .current }
            return OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
            #else
            throw .noFunction
            #endif
        }

        /// inotify_add_watch(2).
        static func addWatch(_ inotify: FileDescriptor, path: String, events: NotifyEvents) throws(Errno) {
            #if os(Linux)
            guard unsafe inotify_add_watch(inotify.rawValue, path, events.rawValue) >= 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        /// Reads queued events until the nonblocking descriptor is empty.
        static func drain(_ inotify: FileDescriptor) throws(Errno) {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                do {
                    let count = try buffer.withUnsafeMutableBytes { bytes in unsafe try inotify.read(into: bytes) }
                    if count == 0 { return }
                } catch Errno.interrupted {
                    continue
                } catch Errno.resourceTemporarilyUnavailable {
                    return
                } catch {
                    throw (error as? Errno) ?? .ioError
                }
            }
        }
    }
}
