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

/// Process setup used by the launch handshake: forking, leaving, and the
/// per-process state a container init changes before exec.
extension Kernel.Process {
    /// fork(2); 0 in the child. The caller must be single-threaded.
    static func fork() throws(Errno) -> pid_t {
        #if os(Linux)
        let pid = libcFork()
        guard pid >= 0 else { throw .current }
        return pid
        #else
        // Darwin marks fork unavailable to Swift; the runtime never forks there.
        throw .noFunction
        #endif
    }

    /// _exit(2): leaves without running atexit handlers or flushing stdio.
    static func exit(_ status: Int32) -> Never {
        _exit(status)
    }

    /// setsid(2).
    static func startSession() throws(Errno) {
        guard setsid() >= 0 else { throw .current }
    }

    /// prctl(PR_SET_PDEATHSIG). Linux clears it when credentials change.
    static func setParentDeathSignal(_ signal: Int32) throws(Errno) {
        #if os(Linux)
        guard linux_set_parent_death_signal(signal) == 0 else { throw .current }
        #else
        throw .noFunction
        #endif
    }

    /// close_range(CLOSE_RANGE_CLOEXEC) from `first` up (Linux 5.11+).
    static func markDescriptorsCloseOnExec(from first: UInt32) throws(Errno) {
        #if os(Linux)
        guard linux_mark_descriptors_cloexec(first) == 0 else { throw .current }
        #else
        throw .noFunction
        #endif
    }

    /// umask(2); returns the previous mask.
    @discardableResult
    static func setFileCreationMask(_ mask: UInt32) -> UInt32 {
        UInt32(umask(mode_t(mask)))
    }

    /// sethostname(2) of a NUL-terminated name.
    static func setHostname(_ name: UnsafePointer<CChar>) throws(Errno) {
        guard unsafe sethostname(name, numericCast(strlen(name))) == 0 else { throw .current }
    }

    /// chdir(2).
    static func changeDirectory(_ path: UnsafePointer<CChar>) throws(Errno) {
        guard unsafe chdir(path) == 0 else { throw .current }
    }

    /// fchdir(2).
    static func changeDirectory(to directory: FileDescriptor) throws(Errno) {
        guard fchdir(directory.rawValue) == 0 else { throw .current }
    }

    /// chroot(2).
    static func changeRoot(_ path: UnsafePointer<CChar>) throws(Errno) {
        guard unsafe chroot(path) == 0 else { throw .current }
    }

    /// execv(3) with this process's environment; returns only the error.
    @unsafe
    static func execute(_ file: UnsafePointer<CChar>, arguments: UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Errno {
        _ = unsafe execv(file, arguments)
        return .current
    }
}

#if os(Linux)
/// fork at file scope, where it is not shadowed by `Kernel.Process.fork`.
private func libcFork() -> pid_t { fork() }
#endif
