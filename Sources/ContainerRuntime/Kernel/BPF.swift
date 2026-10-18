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
    /// bpf(2) for cgroup v2 device programs. The supervisor loads and attaches
    /// them while it prepares the cgroup, before any init joins it.
    enum BPF {
        /// BPF_PROG_LOAD of a BPF_PROG_TYPE_CGROUP_DEVICE program from raw
        /// `bpf_insn` bytes. The verifier's NUL-terminated log is written to
        /// `log` so a rejected program can be explained.
        static func loadDeviceProgram(_ bytes: [UInt8], log: inout [UInt8]) throws(Errno) -> OwnedFileDescriptor {
            #if os(Linux)
            let fd = bytes.withUnsafeBufferPointer { instructions in
                log.withUnsafeMutableBufferPointer { log in
                    unsafe linux_bpf_device_load(instructions.baseAddress, instructions.count, log.baseAddress, log.count)
                }
            }
            guard fd >= 0 else { throw .current }
            return OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: fd))
            #else
            throw .noFunction
            #endif
        }

        /// BPF_PROG_ATTACH with BPF_F_ALLOW_MULTI, so programs attached by
        /// other owners of the cgroup stay in force alongside this one.
        static func attach(_ program: FileDescriptor, to cgroup: FileDescriptor) throws(Errno) {
            #if os(Linux)
            guard linux_bpf_device_attach(program.rawValue, cgroup.rawValue) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        /// BPF_PROG_DETACH of exactly this program from the cgroup.
        static func detach(_ program: FileDescriptor, from cgroup: FileDescriptor) throws(Errno) {
            #if os(Linux)
            guard linux_bpf_device_detach(program.rawValue, cgroup.rawValue) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        /// The kernel-wide program ID, which outlives this process's descriptor
        /// and is recorded so that cleanup can detach the same program later.
        static func id(of program: FileDescriptor) throws(Errno) -> UInt32 {
            #if os(Linux)
            let id = linux_bpf_program_id(program.rawValue)
            guard id != 0 else { throw .current }
            return id
            #else
            throw .noFunction
            #endif
        }

        /// BPF_PROG_GET_FD_BY_ID: ENOENT once the program has been freed.
        static func openProgram(_ id: UInt32) throws(Errno) -> OwnedFileDescriptor {
            #if os(Linux)
            let fd = linux_bpf_program_open(id)
            guard fd >= 0 else { throw .current }
            return OwnedFileDescriptor(takingOwnershipOf: FileDescriptor(rawValue: fd))
            #else
            throw .noFunction
            #endif
        }
    }
}
