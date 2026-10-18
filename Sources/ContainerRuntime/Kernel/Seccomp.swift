#if os(Linux)
import CSeccomp
#endif
import SystemPackage

/// Exported classic BPF and load flags. The parent compiles everything before
/// fork; the child only borrows bytes and invokes seccomp(2).
struct PreparedSeccomp: Sendable {
    /// `struct sock_filter` instructions exported by libseccomp.
    let bytes: [UInt8]
    /// SECCOMP_FILTER_FLAG_* bits passed to seccomp(2).
    let flags: UInt32

    /// Loads the filter into the calling thread. Returns nil or the error.
    func install() -> Errno? {
        Errno.failure { () throws(Errno) in try Kernel.Seccomp.install(bytes, flags: flags) }
    }
}

extension Kernel {
    /// libseccomp filter construction (supervisor only) and seccomp(2) loading.
    enum Seccomp {
        /// Builds the profile with libseccomp and exports it as classic BPF.
        /// Unknown syscall names and architectures fail instead of weakening
        /// the policy; rules whose action equals the default are skipped.
        /// - Throws: `RuntimeError` naming the rejected part of `linux.seccomp`.
        static func compile(_ profile: SeccompProfile) throws -> PreparedSeccomp {
            #if os(Linux)
            let defaultAction = try profile.defaultAction.value(profile.defaultErrnoRet)
            guard let context = unsafe seccomp_init(defaultAction) else { throw RuntimeError("initialize linux.seccomp filter") }
            defer { unsafe seccomp_release(context) }
            func check(_ result: Int32, _ operation: String) throws {
                guard result >= 0 else { throw RuntimeError("linux.seccomp: \(operation): \(Errno(rawValue: -result))") }
            }
            // The runtime applies OCI noNewPrivileges itself, never as an
            // implicit side effect of loading a filter. Keep native arch as runc
            // does and add compat ABIs requested by the engine.
            try check(unsafe seccomp_attr_set(context, SCMP_FLTATR_CTL_NNP, 0), "disable implicit no_new_privs")
            for architecture in profile.architectures ?? [] {
                guard let name = SeccompProfile.architectureNames[architecture] else { throw RuntimeError("linux.seccomp: unknown architecture") }
                let token = name.withCString { unsafe seccomp_arch_resolve_name($0) }
                guard token != 0 else { throw RuntimeError("linux.seccomp: libseccomp does not know \(architecture)") }
                let result = unsafe seccomp_arch_add(context, token)
                if result != -Errno.fileExists.rawValue { try check(result, "add architecture \(architecture)") }
            }
            for rule in profile.syscalls ?? [] {
                let action = try rule.action.value(rule.errnoRet)
                if action == defaultAction { continue }
                let arguments = (rule.args ?? []).map {
                    scmp_arg_cmp(arg: $0.index, op: scmp_compare(rawValue: $0.op.number), datum_a: $0.value, datum_b: $0.valueTwo ?? 0)
                }
                // runc's historical same-index semantics: when any index is
                // repeated, each condition becomes a separate OR rule. Otherwise
                // conditions on distinct indices are ANDed in one rule.
                let repeated = Set((rule.args ?? []).map(\.index)).count < arguments.count
                let groups = repeated ? arguments.map { [$0] } : [arguments]
                for name in rule.names {
                    let number = name.withCString { unsafe seccomp_syscall_resolve_name($0) }
                    // A misspelled deny rule must never silently weaken a policy.
                    // Pseudo syscall numbers below -1 remain valid for compat ABIs.
                    guard number != -1 else { throw RuntimeError("linux.seccomp: unknown syscall \(name)") }
                    for group in groups {
                        let result = group.withUnsafeBufferPointer {
                            unsafe seccomp_rule_add_array(context, action, number, UInt32($0.count), $0.baseAddress)
                        }
                        try check(result, "add rule for \(name)")
                    }
                }
            }
            let raw = unsafe sct_seccomp_export(context)
            try check(raw, "export filter")
            let descriptor = OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: raw))
            let bytes = try descriptor.withDescriptor { try Kernel.File.readAll($0, limit: 4096 * 8) }
            guard !bytes.isEmpty, bytes.count % 8 == 0 else { throw RuntimeError("linux.seccomp: invalid exported bytecode") }
            return PreparedSeccomp(bytes: bytes, flags: try SeccompProfile.kernelFlags(profile.flags))
            #else
            throw RuntimeError("linux.seccomp requires Linux and libseccomp")
            #endif
        }

        /// SECCOMP_SET_MODE_FILTER with prepared bytes. Without no_new_privs
        /// this needs CAP_SYS_ADMIN.
        static func install(_ bytes: [UInt8], flags: UInt32) throws(Errno) {
            #if os(Linux)
            let result = bytes.withUnsafeBufferPointer { unsafe sct_seccomp_install($0.baseAddress, $0.count, flags) }
            guard result == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }
    }
}
