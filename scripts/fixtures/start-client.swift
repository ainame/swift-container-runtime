// A black-box StartGate client for lifecycle integration tests.
//
// Usage: start-client SOCKET_PATH [--send-request]
//
// Connects a close-on-exec SOCK_SEQPACKET socket to SOCKET_PATH, optionally
// sends the start-v1 request, and closes at once without reading a reply.
// Without --send-request it models a start client that dies before asking;
// with it, a client that dies after asking but before the init checks it.
//
// Build: swiftc -strict-memory-safety -warnings-as-errors -I Sources/LinuxAPI \
//            scripts/fixtures/start-client.swift -o /tmp/start-client
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
import LinuxAPI

/// Must match `StartProtocol.request` in StartGate.swift.
let startRequest: [UInt8] = Array("start-v1".utf8)

func fail(_ message: String) -> Never {
    let bytes = Array("start-client: \(message)\n".utf8)
    _ = bytes.withUnsafeBytes { unsafe write(2, $0.baseAddress, $0.count) }
    exit(1)
}

func describe(_ code: Int32) -> String {
    unsafe String(cString: strerror(code))
}

func run(path: String, sendRequest: Bool) {
    // Validate the path against sun_path before touching any descriptor.
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard !bytes.contains(0) else { fail("socket path contains a NUL byte") }
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        fail("socket path is \(bytes.count) bytes; sun_path holds \(MemoryLayout.size(ofValue: address.sun_path) - 1)")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        for (index, byte) in bytes.enumerated() { unsafe buffer[index] = byte }
    }

    // Open the one owned descriptor; it is closed on every return path.
    let socket = linux_unix_seqpacket_socket()
    guard socket >= 0 else { fail("socket: \(describe(errno))") }
    defer { _ = close(socket) }

    // Connect to the filesystem path.
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &address) { pointer in
        unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
            unsafe connect(socket, generic, length)
        }
    }
    guard connected == 0 else { fail("connect \(path): \(describe(errno))") }

    // Optionally send the exact request as one packet, then close without waiting.
    guard sendRequest else { return }
    let sent = startRequest.withUnsafeBytes { request in
        unsafe send(socket, request.baseAddress, request.count, Int32(MSG_NOSIGNAL))
    }
    guard sent == startRequest.count else {
        fail(sent < 0 ? "send: \(describe(errno))" : "send: wrote \(sent) of \(startRequest.count) bytes")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let usage = "usage: start-client SOCKET_PATH [--send-request]"
switch arguments.count {
case 1 where !arguments[0].isEmpty && !arguments[0].hasPrefix("-"):
    run(path: arguments[0], sendRequest: false)
case 2 where !arguments[0].isEmpty && !arguments[0].hasPrefix("-") && arguments[1] == "--send-request":
    run(path: arguments[0], sendRequest: true)
default:
    fail(usage)
}
