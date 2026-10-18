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

extension Kernel {
    /// Credentials, capabilities and limits of the calling process, applied in
    /// the order the launch code decides.
    enum Credentials {
        /// setgroups(2); an empty buffer clears the supplementary groups.
        static func setGroups(_ groups: UnsafeBufferPointer<gid_t>) throws(Errno) {
            guard unsafe setgroups(numericCast(groups.count), groups.baseAddress) == 0 else { throw .current }
        }

        static func setGroupID(_ gid: gid_t) throws(Errno) {
            guard setgid(gid) == 0 else { throw .current }
        }

        static func setUserID(_ uid: uid_t) throws(Errno) {
            guard setuid(uid) == 0 else { throw .current }
        }

        /// prctl(PR_SET_NO_NEW_PRIVS).
        static func setNoNewPrivileges() throws(Errno) {
            #if os(Linux)
            guard linux_set_no_new_privileges() == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        /// prctl(PR_CAPBSET_READ).
        static func boundingSetContains(_ capability: Int32) throws(Errno) -> Bool {
            #if os(Linux)
            let present = linux_read_bounding_capability(capability)
            guard present >= 0 else { throw .current }
            return present != 0
            #else
            throw .noFunction
            #endif
        }

        /// prctl(PR_CAPBSET_DROP); requires CAP_SETPCAP.
        static func dropFromBoundingSet(_ capability: Int32) throws(Errno) {
            #if os(Linux)
            guard linux_drop_bounding_capability(capability) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        /// prctl(PR_SET_KEEPCAPS).
        static func setKeepCapabilities(_ keep: Bool) throws(Errno) {
            #if os(Linux)
            guard linux_set_keep_capabilities(keep ? 1 : 0) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        /// capset(2) of the effective, permitted and inheritable sets.
        static func setCapabilities(effective: UInt64, permitted: UInt64, inheritable: UInt64) throws(Errno) {
            #if os(Linux)
            guard linux_set_capabilities(effective, permitted, inheritable) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        /// prctl(PR_CAP_AMBIENT_CLEAR_ALL).
        static func clearAmbientCapabilities() throws(Errno) {
            #if os(Linux)
            guard linux_clear_ambient_capabilities() == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        /// prctl(PR_CAP_AMBIENT_RAISE).
        static func raiseAmbientCapability(_ capability: Int32) throws(Errno) {
            #if os(Linux)
            guard linux_raise_ambient_capability(capability) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        /// prlimit64(2) on the calling process; `~0` is RLIM_INFINITY.
        static func setResourceLimit(_ resource: Int32, soft: UInt64, hard: UInt64) throws(Errno) {
            #if os(Linux)
            guard linux_set_resource_limit(resource, soft, hard) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }
    }
}
