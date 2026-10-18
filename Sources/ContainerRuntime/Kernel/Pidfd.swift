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

extension Kernel {
    /// Process descriptors (Linux 5.3+), which keep naming a process after it
    /// exits, so a reused PID is never reached through them.
    enum Pidfd {
        /// pidfd_open(2).
        static func open(_ pid: pid_t) throws(Errno) -> OwnedFileDescriptor {
            #if os(Linux)
            let raw = linux_pidfd_open(pid)
            guard raw >= 0 else { throw .current }
            return OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
            #else
            throw .noFunction
            #endif
        }

        /// pidfd_send_signal(2); `ESRCH` once the process has exited.
        static func sendSignal(_ signal: Int32, to pidfd: FileDescriptor) throws(Errno) {
            #if os(Linux)
            guard linux_pidfd_send_signal(pidfd.rawValue, signal) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }
    }
}
