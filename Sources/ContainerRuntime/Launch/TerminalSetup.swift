import SystemPackage

/// `process.terminal` with `--console-socket`, as runc's setupConsole. The
/// supervisor connects to the socket just before the launch forks; the init
/// or exec process then, inside the container root and before credentials
/// change, opens a pseudoterminal from the container's devpts, sends the
/// master over the socket, and makes the peer its stdio and controlling
/// terminal. The engine (for example containerd's shim) owns the master from
/// then on, including I/O and resizing.
final class TerminalSetup {
    private var connection: OwnedFileDescriptor
    /// Rows and columns, applied to the new terminal before handoff.
    private let size: (rows: UInt16, columns: UInt16)?
    /// Init also binds the terminal onto /dev/console; exec does not.
    private let bindsConsole: Bool

    /// Connects to `address` (see ``UnixSocketAddress/connect(relativeTo:)``).
    init(
        connectingTo address: UnixSocketAddress, relativeTo base: String?,
        size: OCIConfiguration.ConsoleSize?, bindsConsole: Bool
    ) throws {
        connection = try address.connect(relativeTo: base)
        self.size = size.map { (rows: $0.height, columns: $0.width) }
        self.bindsConsole = bindsConsole
    }

    /// Runs in the forked process, which is a session leader. Closes the
    /// master and the socket on every path. Returns nil or the failure.
    func setUp() -> LaunchFailure? {
        defer { try? connection.close() }
        var master = OwnedFileDescriptor()
        do {
            master = try Kernel.Terminal.openMaster()
        } catch {
            return LaunchFailure(stage: .openTerminal, error: error)
        }
        var peer = OwnedFileDescriptor()
        if let error = master.failure(in: { master in
            Errno.failure { () throws(Errno) in
                peer = try Kernel.Terminal.openPeer(of: master)
                if let size { try Kernel.Terminal.setWindowSize(master, rows: size.rows, columns: size.columns) }
            }
        }) {
            return LaunchFailure(stage: .openTerminal, error: error)
        }
        if bindsConsole, let error = peer.failure(in: { Self.bindConsole($0) }) {
            return LaunchFailure(stage: .bindConsole, error: error)
        }
        // The payload names the device as runc's SendRawFd does; consumers
        // use only the descriptor.
        if let error = connection.failure(in: { socket in
            master.failure(in: { master in
                Errno.failure { () throws(Errno) in
                    try Kernel.Socket.sendDescriptor(master, over: socket, payload: Array("/dev/pts/ptmx".utf8))
                }
            })
        }) {
            return LaunchFailure(stage: .sendTerminal, error: error)
        }
        try? master.close()
        let error = peer.failure(in: { peer in Errno.failure { () throws(Errno) in try Kernel.Terminal.becomeStdio(peer) } })
        return error.map { LaunchFailure(stage: .terminalStdio, error: $0) }
    }

    func close() {
        try? connection.close()
    }

    /// runc's mountConsole: an empty /dev/console (created when missing, never
    /// opened as a device) with the terminal bind-mounted over it.
    private static func bindConsole(_ terminal: FileDescriptor) -> Errno? {
        Errno.failure { () throws(Errno) in
            let dev = try Kernel.File.openPath("/dev", options: [.directory, .noFollow])
            let target = try dev.borrowDescriptor { dev throws(Errno) in
                do throws(Errno) {
                    try unsafe Kernel.File.makeEmptyFile("console", in: dev, permissions: FilePermissions(rawValue: 0o666))
                } catch .fileExists {
                }
                return try unsafe Kernel.File.openPath("console", in: dev, options: .noFollow)
            }
            let tree = try Kernel.Mount.cloneTree(of: terminal, recursive: false)
            try tree.borrowDescriptor { tree throws(Errno) in
                try target.borrowDescriptor { target throws(Errno) in try Kernel.Mount.attach(tree, onto: target) }
            }
        }
    }
}
