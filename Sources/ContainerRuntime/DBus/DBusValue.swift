/// One D-Bus value together with its complete type, as the wire format needs
/// it: an array names its element type so an empty one still has a signature.
///
/// Only the types the systemd cgroup driver exchanges with systemd, plus the
/// rest of the basic types so any reply body can be decoded, are modelled.
/// Dictionaries decode as arrays of two-field structures.
indirect enum DBusValue: Sendable, Equatable {
    case byte(UInt8)
    case boolean(Bool)
    case int16(Int16)
    case uint16(UInt16)
    case int32(Int32)
    case uint32(UInt32)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case string(String)
    case objectPath(String)
    case signature(String)
    /// An index into the message's descriptor array (`h`). Descriptors are
    /// never passed by this client; the value only decodes.
    case unixFD(UInt32)
    /// Elements that all have the single complete type `element`.
    case array(element: String, [DBusValue])
    case structure([DBusValue])
    /// A dictionary entry (`{kv}`), valid only as an array element.
    case dictionaryEntry(DBusValue, DBusValue)
    case variant(DBusValue)

    /// The value's complete type signature.
    var signature: String {
        switch self {
        case .byte: "y"
        case .boolean: "b"
        case .int16: "n"
        case .uint16: "q"
        case .int32: "i"
        case .uint32: "u"
        case .int64: "x"
        case .uint64: "t"
        case .double: "d"
        case .string: "s"
        case .objectPath: "o"
        case .signature: "g"
        case .unixFD: "h"
        case let .array(element, _): "a" + element
        case let .structure(fields): "(" + fields.map(\.signature).joined() + ")"
        case let .dictionaryEntry(key, value): "{" + key.signature + value.signature + "}"
        case .variant: "v"
        }
    }

    /// The string of a `s`, `o` or `g` value.
    var stringValue: String? {
        switch self {
        case let .string(value), let .objectPath(value), let .signature(value): value
        default: nil
        }
    }

    var uint32Value: UInt32? {
        if case let .uint32(value) = self { return value }
        return nil
    }
}

/// Malformed D-Bus data, from a peer or from a caller building a message.
struct DBusProtocolError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = "D-Bus: " + description
    }
}

/// Signature arithmetic shared by the encoder and decoder.
enum DBusSignature {
    /// The specification's limits: 255 signature bytes, and at most 32
    /// nested arrays plus 32 nested structures.
    static let maximumLength = 255
    static let maximumDepth = 64

    /// Wire alignment of a value whose type starts with `code`.
    static func alignment(of code: UInt8) -> Int {
        switch code {
        case UInt8(ascii: "y"), UInt8(ascii: "g"), UInt8(ascii: "v"): 1
        case UInt8(ascii: "n"), UInt8(ascii: "q"): 2
        case UInt8(ascii: "x"), UInt8(ascii: "t"), UInt8(ascii: "d"), UInt8(ascii: "("), UInt8(ascii: "{"): 8
        default: 4
        }
    }

    /// Splits a signature into its complete types.
    static func completeTypes(_ signature: String) throws -> [String] {
        let bytes = Array(signature.utf8)
        guard bytes.count <= maximumLength else { throw DBusProtocolError("signature exceeds \(maximumLength) bytes") }
        var types: [String] = []
        var index = 0
        while index < bytes.count {
            let end = try endOfCompleteType(bytes, at: index, depth: 0)
            types.append(String(decoding: bytes[index..<end], as: UTF8.self))
            index = end
        }
        return types
    }

    /// The index just past the complete type starting at `start`.
    static func endOfCompleteType(_ bytes: [UInt8], at start: Int, depth: Int) throws -> Int {
        guard depth < maximumDepth else { throw DBusProtocolError("signature nests too deeply") }
        guard start < bytes.count else { throw DBusProtocolError("signature ends inside a type") }
        switch bytes[start] {
        case UInt8(ascii: "a"):
            return try endOfCompleteType(bytes, at: start + 1, depth: depth + 1)
        case UInt8(ascii: "("):
            var index = start + 1
            guard index < bytes.count, bytes[index] != UInt8(ascii: ")") else { throw DBusProtocolError("empty structure in signature") }
            while index < bytes.count, bytes[index] != UInt8(ascii: ")") {
                index = try endOfCompleteType(bytes, at: index, depth: depth + 1)
            }
            guard index < bytes.count else { throw DBusProtocolError("unterminated structure in signature") }
            return index + 1
        case UInt8(ascii: "{"):
            // Only valid as an array element; a basic key and one value.
            guard start > 0, bytes[start - 1] == UInt8(ascii: "a") else {
                throw DBusProtocolError("dictionary entry outside an array in signature")
            }
            let key = start + 1
            guard key < bytes.count, isBasic(bytes[key]) else { throw DBusProtocolError("dictionary key is not a basic type") }
            let valueEnd = try endOfCompleteType(bytes, at: key + 1, depth: depth + 1)
            guard valueEnd < bytes.count, bytes[valueEnd] == UInt8(ascii: "}") else {
                throw DBusProtocolError("dictionary entry must have exactly one key and one value")
            }
            return valueEnd + 1
        case let code where isBasic(code) || code == UInt8(ascii: "v"):
            return start + 1
        case let code:
            throw DBusProtocolError("unknown type code \(Unicode.Scalar(code)) in signature")
        }
    }

    private static func isBasic(_ code: UInt8) -> Bool {
        "ybnqiuxtdsogh".utf8.contains(code)
    }
}

/// Builds the little-endian wire form of values. Alignment is relative to
/// the start of `bytes`, which must be the start of a message or of a body
/// (always 8-aligned within the message).
struct DBusEncoder {
    /// Arrays may hold at most 64 MiB, per the specification.
    static let maximumArrayLength = 1 << 26

    private(set) var bytes: [UInt8] = []

    mutating func pad(to alignment: Int) {
        while bytes.count % alignment != 0 { bytes.append(0) }
    }

    mutating func append(_ value: DBusValue) throws {
        switch value {
        case let .byte(value): bytes.append(value)
        case let .boolean(value): appendInteger(UInt32(value ? 1 : 0))
        case let .int16(value): appendInteger(UInt16(bitPattern: value))
        case let .uint16(value): appendInteger(value)
        case let .int32(value): appendInteger(UInt32(bitPattern: value))
        case let .uint32(value), let .unixFD(value): appendInteger(value)
        case let .int64(value): appendInteger(UInt64(bitPattern: value))
        case let .uint64(value): appendInteger(value)
        case let .double(value): appendInteger(value.bitPattern)
        case let .string(text), let .objectPath(text):
            if case .objectPath = value, !Self.isValidObjectPath(text) { throw DBusProtocolError("invalid object path \(text.debugDescription)") }
            let utf8 = Array(text.utf8)
            guard !utf8.contains(0) else { throw DBusProtocolError("string contains NUL") }
            appendInteger(UInt32(utf8.count))
            bytes += utf8
            bytes.append(0)
        case let .signature(text):
            let utf8 = Array(text.utf8)
            _ = try DBusSignature.completeTypes(text)
            bytes.append(UInt8(utf8.count))
            bytes += utf8
            bytes.append(0)
        case let .array(element, elements):
            let elementTypes = try DBusSignature.completeTypes(element)
            guard elementTypes.count == 1 else { throw DBusProtocolError("array element signature \(element) is not one complete type") }
            pad(to: 4)
            let lengthOffset = bytes.count
            appendInteger(UInt32(0))
            // Padding to the first element is not part of the length.
            pad(to: DBusSignature.alignment(of: Array(element.utf8)[0]))
            let start = bytes.count
            for item in elements {
                guard item.signature == element else {
                    throw DBusProtocolError("array of \(element) contains a \(item.signature) value")
                }
                try append(item)
            }
            let length = bytes.count - start
            guard length <= Self.maximumArrayLength else { throw DBusProtocolError("array exceeds 64 MiB") }
            bytes.replaceSubrange(lengthOffset..<(lengthOffset + 4), with: Self.littleEndianBytes(UInt32(length)))
        case let .structure(fields):
            guard !fields.isEmpty else { throw DBusProtocolError("empty structure") }
            pad(to: 8)
            for field in fields { try append(field) }
        case let .dictionaryEntry(key, value):
            pad(to: 8)
            try append(key)
            try append(value)
        case let .variant(inner):
            try append(.signature(inner.signature))
            try append(inner)
        }
    }

    /// Appends a fixed-size integer in little-endian order after aligning
    /// to its own size, as every D-Bus fixed type is aligned.
    private mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        pad(to: MemoryLayout<T>.size)
        bytes += Self.littleEndianBytes(value)
    }

    static func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    /// `/`, or `/`-separated nonempty elements of `[A-Za-z0-9_]`.
    static func isValidObjectPath(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        if path == "/" { return true }
        let elements = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        return elements.allSatisfy { element in
            !element.isEmpty && element.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "_") }
        }
    }
}

/// Reads values from received bytes in either byte order. Every length and
/// offset is checked against the buffer; nothing is trusted from the peer.
struct DBusDecoder {
    private let bytes: [UInt8]
    private let bigEndian: Bool
    /// The offset of `bytes[0]` within the message, for alignment.
    private let base: Int
    private(set) var offset: Int

    init(_ bytes: [UInt8], bigEndian: Bool, base: Int = 0, offset: Int = 0) {
        self.bytes = bytes
        self.bigEndian = bigEndian
        self.base = base
        self.offset = offset
    }

    var isAtEnd: Bool { offset == bytes.count }

    mutating func skipPadding(to alignment: Int) throws {
        while (base + offset) % alignment != 0 {
            guard offset < bytes.count else { throw DBusProtocolError("message truncated in padding") }
            guard bytes[offset] == 0 else { throw DBusProtocolError("nonzero padding byte") }
            offset += 1
        }
    }

    /// Decodes every complete type in `signature`, in order.
    mutating func values(_ signature: String) throws -> [DBusValue] {
        try DBusSignature.completeTypes(signature).map { try value(Array($0.utf8), depth: 0) }
    }

    /// Decodes one value of the complete type `type`.
    mutating func value(_ type: [UInt8], depth: Int) throws -> DBusValue {
        guard depth < DBusSignature.maximumDepth else { throw DBusProtocolError("value nests too deeply") }
        guard let code = type.first else { throw DBusProtocolError("empty type") }
        switch code {
        case UInt8(ascii: "y"): return .byte(try fixed(UInt8.self))
        case UInt8(ascii: "b"):
            let raw = try fixed(UInt32.self)
            guard raw <= 1 else { throw DBusProtocolError("boolean value \(raw)") }
            return .boolean(raw == 1)
        case UInt8(ascii: "n"): return .int16(Int16(bitPattern: try fixed(UInt16.self)))
        case UInt8(ascii: "q"): return .uint16(try fixed(UInt16.self))
        case UInt8(ascii: "i"): return .int32(Int32(bitPattern: try fixed(UInt32.self)))
        case UInt8(ascii: "u"): return .uint32(try fixed(UInt32.self))
        case UInt8(ascii: "h"): return .unixFD(try fixed(UInt32.self))
        case UInt8(ascii: "x"): return .int64(Int64(bitPattern: try fixed(UInt64.self)))
        case UInt8(ascii: "t"): return .uint64(try fixed(UInt64.self))
        case UInt8(ascii: "d"): return .double(Double(bitPattern: try fixed(UInt64.self)))
        case UInt8(ascii: "s"): return .string(try string())
        case UInt8(ascii: "o"): return .objectPath(try string())
        case UInt8(ascii: "g"): return .signature(try signatureText())
        case UInt8(ascii: "v"):
            let inner = try signatureText()
            let types = try DBusSignature.completeTypes(inner)
            guard types.count == 1 else { throw DBusProtocolError("variant signature \(inner) is not one complete type") }
            return .variant(try value(Array(types[0].utf8), depth: depth + 1))
        case UInt8(ascii: "a"):
            let element = Array(type.dropFirst())
            let length = Int(try fixed(UInt32.self))
            guard length <= DBusEncoder.maximumArrayLength else { throw DBusProtocolError("array exceeds 64 MiB") }
            try skipPadding(to: DBusSignature.alignment(of: element[0]))
            let end = offset + length
            guard end <= bytes.count else { throw DBusProtocolError("array runs past the message") }
            var elements: [DBusValue] = []
            while offset < end {
                elements.append(try value(element, depth: depth + 1))
            }
            guard offset == end else { throw DBusProtocolError("array element runs past the array length") }
            return .array(element: String(decoding: element, as: UTF8.self), elements)
        case UInt8(ascii: "("), UInt8(ascii: "{"):
            try skipPadding(to: 8)
            var fields: [DBusValue] = []
            var index = 1
            while index < type.count - 1 {
                let end = try DBusSignature.endOfCompleteType(type, at: index, depth: depth + 1)
                fields.append(try value(Array(type[index..<end]), depth: depth + 1))
                index = end
            }
            if code == UInt8(ascii: "{") {
                guard fields.count == 2 else { throw DBusProtocolError("dictionary entry without exactly two fields") }
                return .dictionaryEntry(fields[0], fields[1])
            }
            return .structure(fields)
        default:
            throw DBusProtocolError("unknown type code \(Unicode.Scalar(code))")
        }
    }

    /// A fixed-size integer, aligned to its size, in the message's byte order.
    mutating func fixed<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        try skipPadding(to: size)
        guard offset + size <= bytes.count else { throw DBusProtocolError("message truncated in a \(size)-byte value") }
        var value: T = 0
        for index in 0..<size {
            let byte = T(bytes[offset + index])
            value |= bigEndian ? byte << ((size - 1 - index) * 8) : byte << (index * 8)
        }
        offset += size
        return value
    }

    /// A `s` or `o` payload: a 32-bit length, UTF-8 bytes, then NUL.
    private mutating func string() throws -> String {
        let length = Int(try fixed(UInt32.self))
        return try terminatedText(length: length)
    }

    /// A `g` payload: an 8-bit length, the signature, then NUL.
    private mutating func signatureText() throws -> String {
        let length = Int(try fixed(UInt8.self))
        return try terminatedText(length: length)
    }

    private mutating func terminatedText(length: Int) throws -> String {
        guard length < bytes.count, offset + length < bytes.count else { throw DBusProtocolError("string runs past the message") }
        let payload = bytes[offset..<(offset + length)]
        guard bytes[offset + length] == 0, !payload.contains(0) else { throw DBusProtocolError("string is not NUL-terminated exactly once") }
        guard let text = String(validating: payload, as: UTF8.self) else { throw DBusProtocolError("string is not valid UTF-8") }
        offset += length + 1
        return text
    }
}
