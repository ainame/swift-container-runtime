#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import SystemPackage

extension Kernel {
    /// Signal numbers the runtime sends itself; other signals arrive as
    /// numbers parsed from user input.
    enum Signal {
        static let kill = SIGKILL
        static let pipe = SIGPIPE
    }

    enum Process {
        /// getpid(2).
        static var id: pid_t { getpid() }
        /// getppid(2).
        static var parentID: pid_t { getppid() }

        static var effectiveUserID: uid_t { geteuid() }
        static var effectiveGroupID: gid_t { getegid() }

        /// The password database's name for `uid`, or nil.
        static func userName(of uid: uid_t) -> String? {
            guard let entry = unsafe getpwuid(uid), let name = unsafe entry.pointee.pw_name else { return nil }
            return unsafe String(cString: name)
        }

        /// Sleeps the calling thread without signals or timers, for short
        /// synchronous backoff.
        static func sleep(for duration: Duration) {
            _ = poll(nil, 0, duration.pollTimeout)
        }

        /// CLOCK_MONOTONIC as whole seconds and nanoseconds.
        static func monotonicTime() -> (seconds: Int64, nanoseconds: Int64) {
            var now = timespec()
            _ = unsafe clock_gettime(CLOCK_MONOTONIC, &now)
            return (Int64(now.tv_sec), Int64(now.tv_nsec))
        }

        /// kill(2).
        static func signal(_ pid: pid_t, _ signal: Int32) throws(Errno) {
            guard kill(pid, signal) == 0 else { throw .current }
        }

        /// waitpid(2) for `pid`, retried on EINTR; returns the wait status.
        static func wait(_ pid: pid_t) throws(Errno) -> Int32 {
            var status: Int32 = 0
            var result: pid_t
            repeat { result = unsafe waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
            guard result >= 0 else { throw .current }
            return status
        }

        /// execve(2); returns the error only when it fails. Safe between fork
        /// and exec: it takes the caller's C buffers and allocates nothing.
        @unsafe
        static func execute(
            _ file: UnsafePointer<CChar>, arguments: UnsafePointer<UnsafeMutablePointer<CChar>?>,
            environment: UnsafePointer<UnsafeMutablePointer<CChar>?>
        ) -> Errno {
            _ = unsafe execve(file, arguments, environment)
            return .current
        }

        /// posix_spawnp(3) of `arguments` (searched in PATH) with this
        /// process's environment, its stdout and stderr on `output`, and
        /// `closing` closed in the child.
        static func spawn(_ arguments: [String], output: FileDescriptor, closing: FileDescriptor) throws(Errno) -> pid_t {
            var argv: CStringVector
            do { argv = try CStringVector(arguments) } catch { throw .invalidArgument }
            #if canImport(Darwin)
            var actions: posix_spawn_file_actions_t? = nil
            #else
            var actions = unsafe posix_spawn_file_actions_t()
            #endif
            func checked(_ code: Int32) throws(Errno) {
                guard code == 0 else { throw Errno(rawValue: code) }
            }
            try checked(unsafe posix_spawn_file_actions_init(&actions))
            defer { _ = unsafe posix_spawn_file_actions_destroy(&actions) }

            // Close the other end first, then put stdout and stderr on output.
            // Descriptors 1/2 can themselves be pipe ends when stdio was closed.
            try checked(unsafe posix_spawn_file_actions_addclose(&actions, closing.rawValue))
            try checked(unsafe posix_spawn_file_actions_adddup2(&actions, output.rawValue, STDOUT_FILENO))
            try checked(unsafe posix_spawn_file_actions_adddup2(&actions, output.rawValue, STDERR_FILENO))
            if output.rawValue > STDERR_FILENO {
                try checked(unsafe posix_spawn_file_actions_addclose(&actions, output.rawValue))
            }
            var pid: pid_t = 0
            try checked(unsafe argv.withPointers { pointers in
                unsafe posix_spawnp(&pid, pointers[0]!, &actions, nil, pointers, environment)
            })
            return pid
        }

        private static var environment: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> { unsafe environ }
    }
}
