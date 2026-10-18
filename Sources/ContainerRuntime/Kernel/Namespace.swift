#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
#if os(Linux)
import LinuxAPI
#endif
import SystemPackage

extension OCIRunPlan.Namespace {
    /// The CLONE_NEW* flag, with Linux's stable values on every platform.
    var cloneFlag: Int32 {
        switch self {
        case .mount: 0x0002_0000
        case .uts: 0x0400_0000
        case .ipc: 0x0800_0000
        case .pid: 0x2000_0000
        case .network: 0x4000_0000
        }
    }
}

extension Kernel {
    enum Namespace {
        /// unshare(2) of the namespaces in `flags` (CLONE_NEW* bits).
        static func unshare(_ flags: Int32) throws(Errno) {
            #if os(Linux)
            guard LinuxAPI.unshare(flags) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        /// NS_GET_NSTYPE, rejecting ordinary files and mismatched namespaces
        /// before the launcher forks. Paths themselves remain owned by Launch.
        static func type(of descriptor: FileDescriptor) throws(Errno) -> Int32 {
            #if os(Linux)
            let type = linux_namespace_type(descriptor.rawValue)
            guard type >= 0 else { throw .current }
            return type
            #else
            throw .noFunction
            #endif
        }

        /// setns(2) into the namespace open at `descriptor`.
        static func enter(_ descriptor: FileDescriptor, _ namespace: OCIRunPlan.Namespace) throws(Errno) {
            #if os(Linux)
            guard setns(descriptor.rawValue, namespace.cloneFlag) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }
    }
}
