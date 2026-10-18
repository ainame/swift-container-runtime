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
    enum BPF {
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

        static func attach(_ program: FileDescriptor, to cgroup: FileDescriptor) throws(Errno) {
            #if os(Linux)
            guard linux_bpf_device_attach(program.rawValue, cgroup.rawValue) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        static func detach(_ program: FileDescriptor, from cgroup: FileDescriptor) throws(Errno) {
            #if os(Linux)
            guard linux_bpf_device_detach(program.rawValue, cgroup.rawValue) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        static func id(of program: FileDescriptor) throws(Errno) -> UInt32 {
            #if os(Linux)
            let id = linux_bpf_program_id(program.rawValue)
            guard id != 0 else { throw .current }
            return id
            #else
            throw .noFunction
            #endif
        }

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
