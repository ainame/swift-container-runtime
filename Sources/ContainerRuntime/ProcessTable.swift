/// Filters host ps output by the PID column, preserving the caller's
/// requested columns and spacing rather than reconstructing each row.
enum ProcessTable {
    static func filter(_ output: String, pids: [Int32]) throws -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.first,
              let column = header.split(whereSeparator: { $0.isWhitespace }).firstIndex(of: "PID") else {
            throw RuntimeError("couldn't find PID field in ps output")
        }
        let wanted = Set(pids)
        var result = String(header) + "\n"
        for line in lines.dropFirst() where !line.isEmpty {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard column < fields.count, let pid = Int32(fields[column]) else {
                throw RuntimeError("unable to parse PID in ps output: \(line)")
            }
            if wanted.contains(pid) { result += line + "\n" }
        }
        return result
    }
}

#if os(Linux)
#if canImport(Musl)
import Musl
#else
import Glibc
#endif
import SystemPackage

extension ProcessTable {
    /// Uses posix_spawnp rather than forking Swift. Pipe ownership and child
    /// reaping remain scoped even when reading or formatting the output fails.
    static func readHost(arguments: [String]) throws -> String {
        var argv = try CStringVector(["ps"] + (arguments.isEmpty ? ["-ef"] : arguments))
        let pipe = try FileDescriptor.pipe(options: .closeOnExec)
        let reader = OwnedFileDescriptor(takingOwnershipOf: pipe.readEnd)
        var writer = OwnedFileDescriptor(takingOwnershipOf: pipe.writeEnd)
        var actions = unsafe posix_spawn_file_actions_t()
        func checked(_ code: Int32) throws {
            guard code == 0 else { throw RuntimeError("spawn host ps: \(Errno(rawValue: code))") }
        }
        try checked(unsafe posix_spawn_file_actions_init(&actions))
        defer { _ = unsafe posix_spawn_file_actions_destroy(&actions) }

        // Close the read end first, then capture stdout and stderr in one pipe.
        // Descriptors 1/2 can themselves be pipe ends when stdio was closed.
        try checked(unsafe posix_spawn_file_actions_addclose(&actions, pipe.readEnd.rawValue))
        try checked(unsafe posix_spawn_file_actions_adddup2(&actions, pipe.writeEnd.rawValue, STDOUT_FILENO))
        try checked(unsafe posix_spawn_file_actions_adddup2(&actions, pipe.writeEnd.rawValue, STDERR_FILENO))
        if pipe.writeEnd.rawValue > STDERR_FILENO {
            try checked(unsafe posix_spawn_file_actions_addclose(&actions, pipe.writeEnd.rawValue))
        }
        var pid: pid_t = 0
        try checked(unsafe argv.withPointers { pointers in
            unsafe posix_spawnp(&pid, pointers[0]!, &actions, nil, pointers, environ)
        })

        // Until waitpid reaps it, this PID still belongs to our child. On a
        // bounded-read failure, kill and reap it so no blocked writer survives.
        var reaped = false
        defer {
            if !reaped {
                _ = kill(pid, SIGKILL)
                var discarded: Int32 = 0
                while unsafe waitpid(pid, &discarded, 0) < 0 && errno == EINTR {}
            }
        }
        try writer.close()
        let output = String(decoding: try reader.readAll(limit: 32 * 1024 * 1024), as: UTF8.self)
        var status: Int32 = 0
        var waited: pid_t
        repeat { waited = unsafe waitpid(pid, &status, 0) } while waited < 0 && errno == EINTR
        guard waited == pid else { throw RuntimeError("wait for host ps: \(Errno.current)") }
        reaped = true
        guard status == 0 else { throw RuntimeError("host ps failed (wait status \(status)): \(output)") }
        return output
    }
}
#endif
