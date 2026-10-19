import SystemPackage

/// A synchronous, single-threaded D-Bus client connection over a Unix stream
/// socket, used by the supervisor for the systemd cgroup driver.
///
/// It runs inside CLI commands, including between the launcher's fork and
/// the workload's start, so it never creates threads or async tasks: each
/// call writes its request and then reads with `poll` until the reply (or a
/// wanted signal) arrives or a deadline passes. Signals that arrive while a
/// reply is awaited are kept for `waitForSignal`, because systemd may emit
/// a job's completion right after its reply.
///
/// The connection owns its socket (close-on-exec, so no forked workload
/// inherits it) and closes it on deinit.
final class DBusConnection {
    /// Lines of the authentication exchange are short; anything longer is
    /// not a D-Bus server.
    private static let maximumAuthenticationLine = 16 * 1024

    private var socket: OwnedFileDescriptor
    /// Received bytes not yet consumed as a whole message.
    private var buffer: [UInt8] = []
    private var nextSerial: UInt32 = 1
    /// Signals received while waiting for something else, oldest first.
    private var pendingSignals: [DBusMessage] = []

    private init(socket: consuming OwnedFileDescriptor) {
        self.socket = socket
    }

    /// Connects to the socket at `path` and authenticates with the EXTERNAL
    /// mechanism, the kernel-verified peer credentials of this process,
    /// which is what systemd's private socket accepts.
    ///
    /// No `Hello` call is made: that registers a name on a message bus, and a
    /// peer-to-peer socket such as `/run/systemd/private` has no bus daemon.
    static func connect(path: String, timeout: Duration) throws -> DBusConnection {
        let socket: OwnedFileDescriptor
        do { socket = try Kernel.Socket.unixStream() } catch { throw RuntimeError("create D-Bus connection: \(error)") }
        var sunPath = Array(path.utf8)
        sunPath.append(0)
        if let error = socket.failure(in: { descriptor in
            Errno.failure { () throws(Errno) in try Kernel.Socket.connect(descriptor, sunPath: sunPath) }
        }) {
            throw RuntimeError("connect to D-Bus socket \(path): \(error)")
        }
        do {
            return try authenticated(socket, timeout: timeout)
        } catch {
            throw RuntimeError("authenticate to D-Bus socket \(path): \(error)")
        }
    }

    /// Authenticates over an already connected stream and takes ownership of it.
    static func authenticated(_ socket: consuming OwnedFileDescriptor, timeout: Duration) throws -> DBusConnection {
        let connection = DBusConnection(socket: socket)
        try connection.authenticate(deadline: ContinuousClock.now + timeout)
        return connection
    }

    /// The SASL exchange: a NUL byte, `AUTH EXTERNAL` with this process's
    /// effective UID as hexadecimal ASCII, `OK <guid>` back, then `BEGIN`,
    /// after which the stream carries messages.
    private func authenticate(deadline: ContinuousClock.Instant) throws {
        let uid = String(Kernel.Process.effectiveUserID)
        let hexUID = uid.utf8.map { byte in
            let digits = Array("0123456789abcdef".utf8)
            return String(decoding: [digits[Int(byte >> 4)], digits[Int(byte & 0xF)]], as: UTF8.self)
        }.joined()
        try send([0] + Array("AUTH EXTERNAL \(hexUID)\r\n".utf8))
        let reply = try readLine(deadline: deadline)
        guard reply.hasPrefix("OK ") else { throw DBusProtocolError("server refused EXTERNAL authentication: \(reply.debugDescription)") }
        try send(Array("BEGIN\r\n".utf8))
    }

    /// Calls a method and returns its reply. An error reply throws `DBusError`.
    func call(
        destination: String?, path: String, interface: String, member: String, arguments: [DBusValue], timeout: Duration
    ) throws -> DBusMessage {
        let serial = nextSerial
        nextSerial = nextSerial == UInt32.max ? 1 : nextSerial + 1
        let request = try DBusMessage.methodCall(
            serial: serial, destination: destination, path: path, interface: interface, member: member, arguments: arguments)
        try send(try request.encoded())
        let deadline = ContinuousClock.now + timeout
        while true {
            let message = try receive(deadline: deadline, waitingFor: "\(interface).\(member) reply")
            switch message.kind {
            case .methodReturn where message.replySerial == serial:
                return message
            case .error where message.replySerial == serial:
                throw DBusError(reply: message)
            case .signal:
                pendingSignals.append(message)
            default:
                // A reply to an earlier, abandoned call, or a call to us that
                // this client does not serve; neither concerns this call.
                continue
            }
        }
    }

    /// Returns the first signal, received now or earlier, that `matches`.
    /// Earlier non-matching signals are discarded as they are inspected.
    func waitForSignal(timeout: Duration, describing description: String, matching matches: (DBusMessage) -> Bool) throws -> DBusMessage {
        while !pendingSignals.isEmpty {
            let signal = pendingSignals.removeFirst()
            if matches(signal) { return signal }
        }
        let deadline = ContinuousClock.now + timeout
        while true {
            let message = try receive(deadline: deadline, waitingFor: description)
            if message.kind == .signal, matches(message) { return message }
        }
    }

    /// Writes every byte, or fails.
    private func send(_ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            let remaining = Array(bytes[sent...])
            let count: Int
            do {
                count = try socket.withDescriptor { descriptor in try Kernel.Socket.send(descriptor, remaining.span.bytes) }
            } catch {
                throw RuntimeError("send to D-Bus peer: \(error)")
            }
            guard count > 0 else { throw RuntimeError("send to D-Bus peer: \(Errno.ioError)") }
            sent += count
        }
    }

    /// The next complete message, reading as needed until `deadline`.
    private func receive(deadline: ContinuousClock.Instant, waitingFor description: String) throws -> DBusMessage {
        while true {
            if buffer.count >= DBusMessage.fixedHeaderLength {
                let total = try DBusMessage.totalLength(header: buffer.prefix(DBusMessage.fixedHeaderLength))
                if buffer.count >= total {
                    let message = try DBusMessage.decode(Array(buffer[..<total]))
                    buffer.removeFirst(total)
                    return message
                }
            }
            try fill(deadline: deadline, waitingFor: description)
        }
    }

    /// One line of the authentication exchange, without its CRLF.
    private func readLine(deadline: ContinuousClock.Instant) throws -> String {
        while true {
            if let end = buffer.indices.dropLast().first(where: { buffer[$0] == 13 && buffer[$0 + 1] == 10 }) {
                let line = String(decoding: buffer[..<end], as: UTF8.self)
                buffer.removeFirst(end + 2)
                return line
            }
            guard buffer.count < Self.maximumAuthenticationLine else { throw DBusProtocolError("authentication line too long") }
            try fill(deadline: deadline, waitingFor: "authentication reply")
        }
    }

    /// Appends whatever the peer has sent, waiting until `deadline`.
    private func fill(deadline: ContinuousClock.Instant, waitingFor description: String) throws {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw RuntimeError("timed out waiting for D-Bus \(description)") }
        let events = socket.poll(.input, timeout: remaining)
        if events.isEmpty { throw RuntimeError("timed out waiting for D-Bus \(description)") }
        let chunk: [UInt8]
        do {
            chunk = try socket.withDescriptor { descriptor in try Kernel.File.read(descriptor, upTo: 64 * 1024) }
        } catch {
            throw RuntimeError("read from D-Bus peer: \(error)")
        }
        guard !chunk.isEmpty else { throw RuntimeError("D-Bus peer closed the connection while waiting for \(description)") }
        buffer += chunk
    }
}
