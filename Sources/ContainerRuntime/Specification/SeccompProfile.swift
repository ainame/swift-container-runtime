/// Validated OCI policy, stored with container state so exec never rereads a
/// potentially changed or removed source bundle for its security restrictions.
struct SeccompProfile: Codable, Sendable, Equatable {
    enum Action: String, Codable, Sendable {
        case kill = "SCMP_ACT_KILL", killThread = "SCMP_ACT_KILL_THREAD"
        case killProcess = "SCMP_ACT_KILL_PROCESS", trap = "SCMP_ACT_TRAP"
        case errno = "SCMP_ACT_ERRNO", trace = "SCMP_ACT_TRACE"
        case allow = "SCMP_ACT_ALLOW", log = "SCMP_ACT_LOG"

        func value(_ data: UInt32?) throws -> UInt32 {
            if let data {
                guard self == .errno || self == .trace else { throw RuntimeError("linux.seccomp: errnoRet requires ERRNO or TRACE") }
                guard data <= (self == .errno ? 4095 : 65535) else { throw RuntimeError("linux.seccomp: errnoRet is out of range") }
            }
            switch self {
            case .kill, .killThread: return 0
            case .killProcess: return 0x80000000
            case .trap: return 0x00030000
            case .errno: return 0x00050000 | (data ?? 1)
            case .trace: return 0x7ff00000 | (data ?? 1)
            case .allow: return 0x7fff0000
            case .log: return 0x7ffc0000
            }
        }
    }

    struct Argument: Codable, Sendable, Equatable {
        enum Operation: String, Codable, Sendable {
            case ne = "SCMP_CMP_NE", lt = "SCMP_CMP_LT", le = "SCMP_CMP_LE"
            case eq = "SCMP_CMP_EQ", ge = "SCMP_CMP_GE", gt = "SCMP_CMP_GT", maskedEqual = "SCMP_CMP_MASKED_EQ"
            var number: UInt32 {
                switch self { case .ne: 1; case .lt: 2; case .le: 3; case .eq: 4; case .ge: 5; case .gt: 6; case .maskedEqual: 7 }
            }
        }
        let index: UInt32
        let value: UInt64
        let valueTwo: UInt64?
        let op: Operation

        init(from decoder: any Decoder) throws {
            let object = try StrictObject(decoder, allowed: ["index", "value", "valueTwo", "op"])
            index = try object.required("index")
            guard index < 6 else { throw RuntimeError("linux.seccomp: argument index must be 0...5") }
            value = try object.requiredUInt64("value")
            valueTwo = try object.optionalUInt64("valueTwo")
            op = try object.required("op")
        }
    }

    struct Rule: Codable, Sendable, Equatable {
        let names: [String]
        let action: Action
        let errnoRet: UInt32?
        let args: [Argument]?

        init(from decoder: any Decoder) throws {
            let object = try StrictObject(decoder, allowed: ["names", "action", "errnoRet", "args"])
            names = try object.required("names")
            guard !names.isEmpty, names.allSatisfy({ !$0.isEmpty && !$0.utf8.contains(0) }) else {
                throw RuntimeError("linux.seccomp: syscall names must be nonempty and contain no NUL")
            }
            action = try object.required("action")
            errnoRet = try object.optional("errnoRet")
            _ = try action.value(errnoRet)
            args = try object.optional("args")
        }
    }

    let defaultAction: Action
    let defaultErrnoRet: UInt32?
    let architectures: [String]?
    let flags: [String]?
    let syscalls: [Rule]?

    init(from decoder: any Decoder) throws {
        // Notification listeners need their own handoff protocol; never ignore
        // listener fields or accept NOTIFY before that protocol exists.
        let object = try StrictObject(decoder, allowed: ["defaultAction", "defaultErrnoRet", "architectures", "flags", "syscalls"])
        let name: String = try object.required("defaultAction")
        guard let action = Action(rawValue: name) else { throw RuntimeError("linux.seccomp.defaultAction: unsupported action \(name)") }
        defaultAction = action
        defaultErrnoRet = try object.optional("defaultErrnoRet")
        _ = try defaultAction.value(defaultErrnoRet)
        architectures = try object.optional("architectures")
        for arch in architectures ?? [] {
            guard Self.architectureNames[arch] != nil else { throw RuntimeError("linux.seccomp: unsupported architecture \(arch)") }
        }
        flags = try object.optional("flags")
        _ = try Self.kernelFlags(flags)
        syscalls = try object.optional("syscalls")
    }

    static func kernelFlags(_ flags: [String]?) throws -> UInt32 {
        // Like runc's absent-flags default. An explicit [] keeps kernel defaults.
        var result: UInt32 = flags == nil ? 4 : 0
        for flag in flags ?? [] {
            switch flag {
            case "SECCOMP_FILTER_FLAG_TSYNC": result |= 1
            case "SECCOMP_FILTER_FLAG_LOG": result |= 2
            case "SECCOMP_FILTER_FLAG_SPEC_ALLOW": result |= 4
            default: throw RuntimeError("linux.seccomp: unsupported filter flag \(flag)")
            }
        }
        return result
    }

    static let architectureNames: [String: String] = [
        "SCMP_ARCH_X86": "x86", "SCMP_ARCH_X86_64": "x86_64", "SCMP_ARCH_X32": "x32",
        "SCMP_ARCH_ARM": "arm", "SCMP_ARCH_AARCH64": "aarch64",
        "SCMP_ARCH_MIPS": "mips", "SCMP_ARCH_MIPS64": "mips64", "SCMP_ARCH_MIPS64N32": "mips64n32",
        "SCMP_ARCH_MIPSEL": "mipsel", "SCMP_ARCH_MIPSEL64": "mipsel64", "SCMP_ARCH_MIPSEL64N32": "mipsel64n32",
        "SCMP_ARCH_PPC": "ppc", "SCMP_ARCH_PPC64": "ppc64", "SCMP_ARCH_PPC64LE": "ppc64le",
        "SCMP_ARCH_S390": "s390", "SCMP_ARCH_S390X": "s390x", "SCMP_ARCH_PARISC": "parisc",
        "SCMP_ARCH_PARISC64": "parisc64", "SCMP_ARCH_RISCV64": "riscv64", "SCMP_ARCH_LOONGARCH64": "loongarch64",
    ]
}
