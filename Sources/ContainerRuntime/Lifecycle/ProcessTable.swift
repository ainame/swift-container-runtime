
/// Filters host ps output by the PID column, preserving the caller's
/// requested columns and spacing rather than reconstructing each row.
enum ProcessTable {
    static func filter(_ output: String, pids: [pid_t]) throws -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.first,
              let column = header.split(whereSeparator: { $0.isWhitespace }).firstIndex(of: "PID") else {
            throw RuntimeError("couldn't find PID field in ps output")
        }
        let wanted = Set(pids)
        var result = String(header) + "\n"
        for line in lines.dropFirst() where !line.isEmpty {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard column < fields.count, let pid = pid_t(fields[column]) else {
                throw RuntimeError("unable to parse PID in ps output: \(line)")
            }
            if wanted.contains(pid) { result += line + "\n" }
        }
        return result
    }
}

#if os(Linux)
import SystemPackage

extension ProcessTable {
    /// Uses posix_spawnp rather than forking Swift. Pipe ownership and child
    /// reaping remain scoped even when reading or formatting the output fails.
    static func readHost(arguments: [String]) throws -> String {
        let pipe = try FileDescriptor.pipe(options: .closeOnExec)
        let reader = OwnedFileDescriptor(takingOwnershipOf: pipe.readEnd)
        var writer = OwnedFileDescriptor(takingOwnershipOf: pipe.writeEnd)
        // stdout and stderr share the pipe; the child closes the read end.
        let pid: pid_t
        do {
            pid = try Kernel.Process.spawn(
                ["ps"] + (arguments.isEmpty ? ["-ef"] : arguments), output: pipe.writeEnd, closing: pipe.readEnd)
        } catch {
            throw RuntimeError("spawn host ps: \(error)")
        }

        // Until waitpid reaps it, this PID still belongs to our child. On a
        // bounded-read failure, kill and reap it so no blocked writer survives.
        var reaped = false
        defer {
            if !reaped {
                try? Kernel.Process.signal(pid, Kernel.Signal.kill)
                _ = try? Kernel.Process.wait(pid)
            }
        }
        try writer.close()
        let output = String(decoding: try reader.readAll(limit: 32 * 1024 * 1024), as: UTF8.self)
        let status: Int32
        do { status = try Kernel.Process.wait(pid) } catch { throw RuntimeError("wait for host ps: \(error)") }
        reaped = true
        guard status == 0 else { throw RuntimeError("host ps failed (wait status \(status)): \(output)") }
        return output
    }
}
#endif
