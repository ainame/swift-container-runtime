import SystemPackage
import Testing
@testable import ContainerRuntime

// MARK: Wire format

@Test func encodesAMethodCallByteForByte() throws {
    let message = try DBusMessage.methodCall(serial: 1, destination: nil, path: "/", interface: "", member: "Ping", arguments: [])
    var call = message
    call.interface = nil
    let expected: [UInt8] = [
        0x6C, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x1D, 0x00, 0x00, 0x00,
        // (PATH, variant "o" "/"), padded to the next structure.
        0x01, 0x01, 0x6F, 0x00, 0x01, 0x00, 0x00, 0x00, 0x2F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // (MEMBER, variant "s" "Ping"), then padding to the 8-aligned body.
        0x03, 0x01, 0x73, 0x00, 0x04, 0x00, 0x00, 0x00, 0x50, 0x69, 0x6E, 0x67, 0x00, 0x00, 0x00, 0x00,
    ]
    #expect(try call.encoded() == expected)
}

@Test func roundTripsSystemdStartTransientUnitArguments() throws {
    let arguments: [DBusValue] = [
        .string("docker-abc.scope"), .string("replace"),
        .array(element: "(sv)", [
            .structure([.string("Delegate"), .variant(.boolean(true))]),
            .structure([.string("PIDs"), .variant(.array(element: "u", [.uint32(4242)]))]),
            .structure([.string("MemoryMax"), .variant(.uint64(.max))]),
            .structure([.string("AllowedCPUs"), .variant(.array(element: "y", [.byte(0x0F)]))]),
        ]),
        .array(element: "(sa(sv))", []),
    ]
    let call = try DBusMessage.methodCall(
        serial: 7, destination: "org.freedesktop.systemd1", path: "/org/freedesktop/systemd1",
        interface: "org.freedesktop.systemd1.Manager", member: "StartTransientUnit", arguments: arguments)
    #expect(call.bodySignature == "ssa(sv)a(sa(sv))")
    let decoded = try DBusMessage.decode(try call.encoded())
    #expect(decoded.kind == .methodCall)
    #expect(decoded.serial == 7)
    #expect(decoded.destination == "org.freedesktop.systemd1")
    #expect(decoded.path == "/org/freedesktop/systemd1")
    #expect(decoded.member == "StartTransientUnit")
    #expect(try decoded.arguments() == arguments)
}

@Test func emptyArrayLengthExcludesElementPadding() throws {
    var encoder = DBusEncoder()
    try encoder.append(.array(element: "t", []))
    // The length word, then padding to the 8-byte element alignment.
    #expect(encoder.bytes == [0, 0, 0, 0, 0, 0, 0, 0])
}

@Test func decodesBigEndianJobRemovedSignal() throws {
    // JobRemoved(u 9, o "/org/freedesktop/systemd1/job/9", s "a.scope", s "done"),
    // built in big-endian by hand from little-endian fields.
    let body: [UInt8] = bigEndian([
        .uint32(9), .objectPath("/org/freedesktop/systemd1/job/9"), .string("a.scope"), .string("done"),
    ])
    var fields: [UInt8] = []
    func field(_ code: UInt8, _ signature: Character, _ text: String) {
        while fields.count % 8 != 0 { fields.append(0) }
        fields += [code, 1, UInt8(ascii: signature.unicodeScalars.first!), 0]
        if signature == "g" {
            fields += [UInt8(text.utf8.count)] + Array(text.utf8) + [0]
        } else {
            fields += bytesBE(UInt32(text.utf8.count)) + Array(text.utf8) + [0]
        }
    }
    field(1, "o", "/org/freedesktop/systemd1")
    field(2, "s", "org.freedesktop.systemd1.Manager")
    field(3, "s", "JobRemoved")
    field(8, "g", "uoss")
    var message: [UInt8] = [UInt8(ascii: "B"), 4, 0, 1] + bytesBE(UInt32(body.count)) + bytesBE(UInt32(3)) + bytesBE(UInt32(fields.count)) + fields
    while message.count % 8 != 0 { message.append(0) }
    message += body

    let decoded = try DBusMessage.decode(message)
    #expect(decoded.kind == .signal)
    #expect(decoded.member == "JobRemoved")
    #expect(try decoded.arguments() == [
        .uint32(9), .objectPath("/org/freedesktop/systemd1/job/9"), .string("a.scope"), .string("done"),
    ])
}

@Test func rejectsMalformedMessages() throws {
    let valid = try DBusMessage.methodCall(serial: 1, destination: nil, path: "/a", interface: "x.y", member: "M", arguments: [.string("hi")]).encoded()
    // Truncated, wrong byte order marker, unknown type, zero serial.
    #expect(throws: (any Error).self) { try DBusMessage.decode(Array(valid.dropLast())) }
    var marker = valid; marker[0] = UInt8(ascii: "x")
    #expect(throws: (any Error).self) { try DBusMessage.decode(marker) }
    var kind = valid; kind[1] = 9
    #expect(throws: (any Error).self) { try DBusMessage.decode(kind) }
    var serial = valid; serial[8] = 0
    #expect(throws: (any Error).self) { try DBusMessage.decode(serial) }
    // A string without its terminating NUL.
    var body = valid; body[body.count - 1] = UInt8(ascii: "!")
    let unterminated = try DBusMessage.decode(body)
    #expect(throws: (any Error).self) { try unterminated.arguments() }
}

@Test func rejectsInvalidValuesWhenEncoding() {
    var encoder = DBusEncoder()
    #expect(throws: (any Error).self) { try encoder.append(.objectPath("relative")) }
    #expect(throws: (any Error).self) { try encoder.append(.objectPath("/a//b")) }
    #expect(throws: (any Error).self) { try encoder.append(.string("nul\u{0}inside")) }
    #expect(throws: (any Error).self) { try encoder.append(.array(element: "u", [.string("x")])) }
    #expect(throws: (any Error).self) { try encoder.append(.array(element: "uu", [])) }
    #expect(throws: (any Error).self) { try encoder.append(.structure([])) }
}

@Test(arguments: ["(", "a", "{sv}", "a{vs}", "a{sss}", "()", "z"])
func rejectsInvalidSignatures(_ signature: String) {
    #expect(throws: (any Error).self) { try DBusSignature.completeTypes(signature) }
}

@Test func splitsCompleteTypes() throws {
    #expect(try DBusSignature.completeTypes("ssa(sv)a(sa(sv))") == ["s", "s", "a(sv)", "a(sa(sv))"])
    #expect(try DBusSignature.completeTypes("a{sv}uoss") == ["a{sv}", "u", "o", "s", "s"])
}

// MARK: Connection, against a scripted peer

#if os(Linux)
/// The peer's replies are written before the client reads, so the exchange
/// runs on one thread through the socket buffers.
@Test func authenticatesCallsAndKeepsEarlySignals() throws {
    let (client, server) = try Kernel.Socket.unixStreamPair()
    let serverEnd = OwnedFileDescriptor(takingOwnershipOf: server)
    func serve(_ bytes: [UInt8]) throws {
        _ = try serverEnd.withDescriptor { try Kernel.Socket.send($0, bytes.span.bytes) }
    }
    try serve(Array("OK 0123456789abcdef0123456789abcdef\r\n".utf8))
    let connection = try DBusConnection.authenticated(OwnedFileDescriptor(takingOwnershipOf: client), timeout: .seconds(5))

    // What the client sent: NUL, AUTH EXTERNAL with the hex-encoded UID, BEGIN.
    let greeting = try serverEnd.withDescriptor { try Kernel.File.read($0, upTo: 4096) }
    let uid = String(Kernel.Process.effectiveUserID).utf8.map { byte in
        let digits = Array("0123456789abcdef".utf8)
        return String(decoding: [digits[Int(byte >> 4)], digits[Int(byte & 0xF)]], as: UTF8.self)
    }.joined()
    #expect(greeting == [0] + Array("AUTH EXTERNAL \(uid)\r\nBEGIN\r\n".utf8))

    // A signal that precedes the reply, then the reply to serial 1.
    var signal = DBusMessage(kind: .signal, serial: 50)
    signal.path = "/org/freedesktop/systemd1"
    signal.interface = "org.freedesktop.systemd1.Manager"
    signal.member = "JobRemoved"
    var encoder = DBusEncoder()
    for value: DBusValue in [.uint32(1), .objectPath("/job/1"), .string("a.scope"), .string("done")] { try encoder.append(value) }
    signal.bodySignature = "uoss"
    signal.body = encoder.bytes
    var reply = DBusMessage(kind: .methodReturn, serial: 51)
    reply.replySerial = 1
    var replyBody = DBusEncoder()
    try replyBody.append(.objectPath("/job/1"))
    reply.bodySignature = "o"
    reply.body = replyBody.bytes
    try serve(try signal.encoded() + reply.encoded())

    let answer = try connection.call(destination: nil, path: "/", interface: "a.b", member: "Start", arguments: [], timeout: .seconds(5))
    #expect(try answer.arguments() == [.objectPath("/job/1")])
    let removed = try connection.waitForSignal(timeout: .seconds(5), describing: "job") { $0.member == "JobRemoved" }
    #expect(try removed.arguments()[3] == .string("done"))

    // An error reply to the next call throws its name and message.
    var failure = DBusMessage(kind: .error, serial: 52)
    failure.replySerial = 2
    failure.errorName = "org.freedesktop.systemd1.NoSuchUnit"
    var failureBody = DBusEncoder()
    try failureBody.append(.string("Unit x.scope not loaded."))
    failure.bodySignature = "s"
    failure.body = failureBody.bytes
    try serve(try failure.encoded())
    #expect {
        _ = try connection.call(destination: nil, path: "/", interface: "a.b", member: "Stop", arguments: [], timeout: .seconds(5))
    } throws: { error in
        (error as? DBusError)?.name == "org.freedesktop.systemd1.NoSuchUnit" && (error as? DBusError)?.message == "Unit x.scope not loaded."
    }

    // A silent peer times out.
    #expect(throws: (any Error).self) {
        _ = try connection.call(destination: nil, path: "/", interface: "a.b", member: "Wait", arguments: [], timeout: .milliseconds(50))
    }
}

@Test func refusedAuthenticationFails() throws {
    let (client, server) = try Kernel.Socket.unixStreamPair()
    let serverEnd = OwnedFileDescriptor(takingOwnershipOf: server)
    _ = try serverEnd.withDescriptor { try Kernel.Socket.send($0, Array("REJECTED EXTERNAL\r\n".utf8).span.bytes) }
    #expect(throws: (any Error).self) {
        _ = try DBusConnection.authenticated(OwnedFileDescriptor(takingOwnershipOf: client), timeout: .seconds(5))
    }
}
#endif

// MARK: Helpers

private func bytesBE(_ value: UInt32) -> [UInt8] {
    (0..<4).map { UInt8(truncatingIfNeeded: value >> ((3 - $0) * 8)) }
}

/// Encodes `uoss`-shaped bodies (32-bit and string fields only) in
/// big-endian order, which the encoder never produces itself.
private func bigEndian(_ values: [DBusValue]) -> [UInt8] {
    var bytes: [UInt8] = []
    for value in values {
        while bytes.count % 4 != 0 { bytes.append(0) }
        switch value {
        case let .uint32(number): bytes += bytesBE(number)
        case let .string(text), let .objectPath(text): bytes += bytesBE(UInt32(text.utf8.count)) + Array(text.utf8) + [0]
        default: Issue.record("unsupported value \(value)")
        }
    }
    return bytes
}
