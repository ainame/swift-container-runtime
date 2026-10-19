/// One D-Bus message: the fixed header, the header fields this client uses,
/// and the body. Outgoing messages are always little-endian; received ones
/// may use either byte order.
struct DBusMessage: Sendable {
    enum Kind: UInt8, Sendable {
        case methodCall = 1, methodReturn = 2, error = 3, signal = 4
    }

    /// Header field codes from the specification.
    private enum Field: UInt8 {
        case path = 1, interface, member, errorName, replySerial, destination, sender, signature, unixFDs
    }

    /// Protocol version 1, the only one defined.
    static let protocolVersion: UInt8 = 1
    /// The specification's 128 MiB limit is far above anything systemd sends
    /// here; a smaller cap bounds what a misbehaving peer can make this
    /// process allocate.
    static let maximumLength = 16 << 20
    /// The fixed header plus the header-field array's length word.
    static let fixedHeaderLength = 16

    var kind: Kind
    /// Nonzero; replies name it as their reply serial.
    var serial: UInt32
    var path: String? = nil
    var interface: String? = nil
    var member: String? = nil
    var errorName: String? = nil
    var replySerial: UInt32? = nil
    var destination: String? = nil
    var sender: String? = nil
    /// The body's signature; empty for no body.
    var bodySignature: String = ""
    /// The encoded body, aligned relative to its own start (which is 8-aligned
    /// in the message, so alignment matches).
    var body: [UInt8] = []
    /// The byte order of `body`.
    var bigEndian = false

    /// A method call with `arguments` as its body.
    static func methodCall(
        serial: UInt32, destination: String?, path: String, interface: String, member: String, arguments: [DBusValue]
    ) throws -> DBusMessage {
        var encoder = DBusEncoder()
        for argument in arguments { try encoder.append(argument) }
        return DBusMessage(
            kind: .methodCall, serial: serial, path: path, interface: interface, member: member, destination: destination,
            bodySignature: arguments.map(\.signature).joined(), body: encoder.bytes)
    }

    /// The decoded body arguments.
    func arguments() throws -> [DBusValue] {
        var decoder = DBusDecoder(body, bigEndian: bigEndian)
        let values = try decoder.values(bodySignature)
        guard decoder.isAtEnd else { throw DBusProtocolError("message body has trailing bytes") }
        return values
    }

    /// The complete wire form.
    func encoded() throws -> [UInt8] {
        guard serial != 0 else { throw DBusProtocolError("message serial 0") }
        var fields: [DBusValue] = []
        func add(_ field: Field, _ value: DBusValue) {
            fields.append(.structure([.byte(field.rawValue), .variant(value)]))
        }
        if let path { add(.path, .objectPath(path)) }
        if let interface { add(.interface, .string(interface)) }
        if let member { add(.member, .string(member)) }
        if let errorName { add(.errorName, .string(errorName)) }
        if let replySerial { add(.replySerial, .uint32(replySerial)) }
        if let destination { add(.destination, .string(destination)) }
        if let sender { add(.sender, .string(sender)) }
        if !bodySignature.isEmpty { add(.signature, .signature(bodySignature)) }

        var encoder = DBusEncoder()
        try encoder.append(.byte(UInt8(ascii: "l")))
        try encoder.append(.byte(kind.rawValue))
        // No flags: every call here expects a reply, and systemd is running.
        try encoder.append(.byte(0))
        try encoder.append(.byte(Self.protocolVersion))
        try encoder.append(.uint32(UInt32(body.count)))
        try encoder.append(.uint32(serial))
        try encoder.append(.array(element: "(yv)", fields))
        encoder.pad(to: 8)
        let message = encoder.bytes + body
        guard message.count <= Self.maximumLength else { throw DBusProtocolError("message exceeds \(Self.maximumLength) bytes") }
        return message
    }

    /// The total length of the message whose first 16 bytes are `header`,
    /// so a reader knows how much to wait for.
    static func totalLength(header: ArraySlice<UInt8>) throws -> Int {
        let header = Array(header)
        guard header.count >= fixedHeaderLength else { throw DBusProtocolError("short message header") }
        let bigEndian = try byteOrder(header[0])
        guard header[3] == protocolVersion else { throw DBusProtocolError("unsupported protocol version \(header[3])") }
        var decoder = DBusDecoder(header, bigEndian: bigEndian, offset: 4)
        let bodyLength = Int(try decoder.fixed(UInt32.self))
        _ = try decoder.fixed(UInt32.self)
        let fieldsLength = Int(try decoder.fixed(UInt32.self))
        guard bodyLength <= maximumLength, fieldsLength <= maximumLength else { throw DBusProtocolError("message exceeds \(maximumLength) bytes") }
        let headerEnd = (fixedHeaderLength + fieldsLength + 7) / 8 * 8
        let total = headerEnd + bodyLength
        guard total <= maximumLength else { throw DBusProtocolError("message exceeds \(maximumLength) bytes") }
        return total
    }

    /// Parses one complete message, as framed by `totalLength(header:)`.
    static func decode(_ bytes: [UInt8]) throws -> DBusMessage {
        let total = try totalLength(header: bytes.prefix(fixedHeaderLength))
        guard bytes.count == total else { throw DBusProtocolError("message length mismatch") }
        let bigEndian = try byteOrder(bytes[0])
        guard let kind = Kind(rawValue: bytes[1]) else { throw DBusProtocolError("unknown message type \(bytes[1])") }

        var decoder = DBusDecoder(bytes, bigEndian: bigEndian, offset: 4)
        let bodyLength = Int(try decoder.fixed(UInt32.self))
        let serial = try decoder.fixed(UInt32.self)
        guard serial != 0 else { throw DBusProtocolError("message serial 0") }
        guard case let .array(_, fields) = try decoder.value(Array("a(yv)".utf8), depth: 0) else {
            throw DBusProtocolError("malformed header fields")
        }
        try decoder.skipPadding(to: 8)
        guard decoder.offset + bodyLength == bytes.count else { throw DBusProtocolError("message body length mismatch") }

        var message = DBusMessage(kind: kind, serial: serial)
        message.bigEndian = bigEndian
        message.body = Array(bytes[decoder.offset...])
        // Unknown header fields must be ignored; known ones must have their
        // specified types, or the message is invalid.
        for field in fields {
            guard case let .structure(parts) = field, parts.count == 2, case let .byte(code) = parts[0],
                  case let .variant(value) = parts[1] else { throw DBusProtocolError("malformed header field") }
            guard let known = Field(rawValue: code) else { continue }
            switch (known, value) {
            case let (.path, .objectPath(text)): message.path = text
            case let (.interface, .string(text)): message.interface = text
            case let (.member, .string(text)): message.member = text
            case let (.errorName, .string(text)): message.errorName = text
            case let (.replySerial, .uint32(number)): message.replySerial = number
            case let (.destination, .string(text)): message.destination = text
            case let (.sender, .string(text)): message.sender = text
            case let (.signature, .signature(text)): message.bodySignature = text
            case (.unixFDs, .uint32): break
            default: throw DBusProtocolError("header field \(code) has type \(value.signature)")
            }
        }
        if kind == .methodReturn || kind == .error, message.replySerial == nil {
            throw DBusProtocolError("reply without a reply serial")
        }
        if kind == .error, message.errorName == nil { throw DBusProtocolError("error without an error name") }
        if kind == .signal, message.path == nil || message.interface == nil || message.member == nil {
            throw DBusProtocolError("signal without path, interface and member")
        }
        return message
    }

    private static func byteOrder(_ marker: UInt8) throws -> Bool {
        switch marker {
        case UInt8(ascii: "l"): false
        case UInt8(ascii: "B"): true
        default: throw DBusProtocolError("unknown byte-order marker \(marker)")
        }
    }
}

/// An error reply from the peer: its D-Bus error name and, when the body
/// starts with a string, that message.
struct DBusError: Error, CustomStringConvertible {
    let name: String
    let message: String

    var description: String { message.isEmpty ? name : "\(name): \(message)" }

    init(name: String, message: String) {
        self.name = name
        self.message = message
    }

    init(reply: DBusMessage) {
        let first = (try? reply.arguments())?.first?.stringValue
        self.init(name: reply.errorName ?? "org.freedesktop.DBus.Error.Failed", message: first ?? "")
    }
}
