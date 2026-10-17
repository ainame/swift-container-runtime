import ArgumentParser
import ContainerRuntime
import SystemPackage

struct Update: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update", abstract: "Update a live container's resource limits.", discussion: "A resources file (or - for stdin) takes precedence over individual flags, as in runc.")
    @OptionGroup var globals: GlobalOptions
    @Option(name: [.customShort("r"), .long]) var resources: String?
    @Option(parsing: .unconditional) var memory: String?
    @Option(parsing: .unconditional) var memorySwap: String?
    @Option(parsing: .unconditional) var memoryReservation: String?
    @Option(parsing: .unconditional) var cpuQuota: String?
    @Option var cpuPeriod: String?
    @Option(name: [.customLong("cpu-share"), .customLong("cpu-shares")]) var cpuShares: String?
    @Option var cpuBurst: String?
    @Option(parsing: .unconditional) var cpuIdle: String?
    @Option var cpusetCpus: String?
    @Option var cpusetMems: String?
    @Option(parsing: .unconditional) var pidsLimit: Int64?
    @Argument var id: String

    mutating func validate() throws {
        _ = try validatedID(id)
        if let resources, resources.isEmpty || resources.utf8.contains(0) {
            throw ValidationError("resources path must be nonempty and contain no NUL")
        }
    }

    func request() throws -> ResourceUpdate {
        // Decode resource files first: their fields replace flag input,
        // rather than being overlaid by flags as in the Kotlin companion.
        if let resources {
            let descriptor = resources == "-" ? FileDescriptor.standardInput : try FileDescriptor.open(FilePath(resources), .readOnly, options: .closeOnExec)
            defer { if resources != "-" { try? descriptor.close() } }
            var bytes: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = try buffer.withUnsafeMutableBytes { unsafe try descriptor.read(into: $0) }
                if count == 0 { break }
                bytes += buffer[..<count]
                guard bytes.count <= 1 << 20 else { throw ValidationError("resources JSON exceeds 1 MiB") }
            }
            return try ResourceUpdate(json: bytes)
        }
        func signed(_ value: String?) throws -> Int64? {
            guard let value, !value.isEmpty else { return nil }
            guard let number = Int64(value) else { throw ValidationError("invalid signed resource integer: \(value)") }
            return number
        }
        func unsigned(_ value: String?) throws -> UInt64? {
            guard let value, !value.isEmpty else { return nil }
            guard let number = UInt64(value) else { throw ValidationError("invalid unsigned resource integer: \(value)") }
            return number
        }
        func memorySize(_ value: String?) throws -> Int64? {
            guard let value, !value.isEmpty else { return nil }
            return try parseRAMBytes(value)
        }
        return try ResourceUpdate(
            memory: memorySize(memory), memorySwap: memorySize(memorySwap), memoryReservation: memorySize(memoryReservation),
            cpuQuota: signed(cpuQuota), cpuPeriod: unsigned(cpuPeriod), cpuShares: unsigned(cpuShares), cpuBurst: unsigned(cpuBurst),
            cpuIdle: signed(cpuIdle), cpusetCpus: cpusetCpus, cpusetMems: cpusetMems, pidsLimit: pidsLimit
        )
    }

    mutating func run() throws {
        do { try globals.lifecycle().update(id: ContainerID(id), resources: request()) }
        catch { throw failure(error) }
    }
}

/// docker/go-units RAMInBytes uses binary multipliers, accepts decimal
/// fractions, and truncates fractional bytes. -1 is runc's unlimited value.
func parseRAMBytes(_ text: String) throws -> Int64 {
    if text == "-1" { return -1 }
    guard let boundary = text.lastIndex(where: { $0.isASCII && ($0.isNumber || $0 == "." || $0 == " ") }) else {
        throw ValidationError("invalid memory size: \(text)")
    }
    let end = text.index(after: boundary)
    let number = text[boundary] == " " ? text[..<boundary] : text[..<end]
    let suffix = text[end...].lowercased()
    var multiplier: Double = 1
    if !suffix.isEmpty && suffix != "b" {
        guard let first = suffix.first, let power = "kmgtp".firstIndex(of: first) else { throw ValidationError("invalid memory unit: \(suffix)") }
        let tail = suffix.dropFirst()
        guard tail.isEmpty || tail == "b" || tail == "ib" else { throw ValidationError("invalid memory unit: \(suffix)") }
        for _ in 0..."kmgtp".distance(from: "kmgtp".startIndex, to: power) { multiplier *= 1024 }
    }
    guard let value = Double(number), value >= 0, value.isFinite,
          let bytes = Int64(exactly: (value * multiplier).rounded(.towardZero)) else {
        throw ValidationError("memory size is invalid or exceeds Int64: \(text)")
    }
    return bytes
}
