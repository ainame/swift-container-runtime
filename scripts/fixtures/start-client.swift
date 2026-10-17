// A black-box StartGate client for lifecycle integration tests.
//
// Usage: start-client SOCKET_PATH [--send-request | --await-accept | --unlink-without-commit]
//
// Connects a close-on-exec SOCK_SEQPACKET socket to SOCKET_PATH and models a
// start client that dies at one point of the handshake, closing at once:
//   (no option)              before sending its request;
//   --send-request           after the request, before the init checks it;
//   --await-accept           after the init accepted, before the marker unlink;
//   --unlink-without-commit  after unlinking SOCKET_PATH, before the commit.
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
let startRequest: [UInt8] = Array("start-v2".utf8)
/// `LaunchRecord`: five Int32/Int64 fields totalling 24 bytes; `accepted` is kind 4.
let recordSize = 24
let acceptedKind: Int32 = 4

enum Stage: String {
    case connect = "", sendRequest = "--send-request", awaitAccept = "--await-accept"
    case unlinkWithoutCommit = "--unlink-without-commit"
}

func fail(_ message: String) -> Never {
    let bytes = Array("start-client: \(message)\n".utf8)
    _ = bytes.withUnsafeBytes { unsafe write(2, $0.baseAddress, $0.count) }
    exit(1)
}

func describe(_ code: Int32) -> String {
    unsafe String(cString: strerror(code))
}

func run(path: String, stage: Stage) {
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
    guard stage != .connect else { return }

    // Send the exact request as one packet.
    let sent = startRequest.withUnsafeBytes { request in
        unsafe send(socket, request.baseAddress, request.count, Int32(MSG_NOSIGNAL))
    }
    guard sent == startRequest.count else {
        fail(sent < 0 ? "send: \(describe(errno))" : "send: wrote \(sent) of \(startRequest.count) bytes")
    }
    guard stage != .sendRequest else { return }

    // Wait (bounded) for the init's acceptance record.
    var peer = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
    guard unsafe poll(&peer, 1, 10_000) == 1 else { fail("no acceptance from the init within 10 seconds") }
    var record = [UInt8](repeating: 0, count: 64)
    let received = record.withUnsafeMutableBytes { buffer in unsafe recv(socket, buffer.baseAddress, buffer.count, 0) }
    guard received == recordSize else { fail("expected a \(recordSize)-byte record, received \(received)") }
    let kind = record.withUnsafeBytes { unsafe $0.loadUnaligned(as: Int32.self) }
    guard kind == acceptedKind else { fail("expected an accepted record, received kind \(kind)") }
    guard stage != .awaitAccept else { return }

    // Consume the marker as `start` would, then vanish without committing.
    guard unsafe unlink(path) == 0 else { fail("unlink \(path): \(describe(errno))") }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let usage = "usage: start-client SOCKET_PATH [--send-request | --await-accept | --unlink-without-commit]"
guard (1...2).contains(arguments.count), !arguments[0].isEmpty, !arguments[0].hasPrefix("-"),
      let stage = Stage(rawValue: arguments.count == 2 ? arguments[1] : ""),
      arguments.count == 1 || stage != .connect else {
    fail(usage)
}
run(path: arguments[0], stage: stage)
